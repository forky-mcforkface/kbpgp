{RSA} = require './rsa'
K = require('./const').kb
C = require('./const').openpgp
{make_esc} = require 'iced-error'
{bufeq_secure,unix_time,bufferify} = require './util'
{Lifespan,Subkey,Primary} = require './keywrapper'
{read_base64,box,unbox} = require './keybase/encode'

{encode,decode} = require './openpgp/armor'
{parse} = require './openpgp/parser'
{KeyBlock} = require './openpgp/processor'

opkts = require './openpgp/packet/all'
kpkts = require './keybase/packet/all'

##
## KeyManager
## 
##   Manage the generation, import and export of keys, in either OpenPGP or
##   keybase form.
##

#=================================================================

class Encryption 
  constructor : ({@tsenc, passphrase}) ->
    @passphrase = bufferify passphrase
    @tsenc or= new triplesec.Encryptor { version : 2, @passphrase }

#=================================================================

class UserIds
  constructor : ({@openpgp, @keybase}) ->
  get_keybase : () -> @keybase
  get_openpgp : () -> @openpgp 

#=================================================================

class Engine
  constructor : ({@primary, @subkeys, @userids}) ->
    @packets = []
    @messages = []
    @_allocate_key_packets()

  #---------

  ekid : (k) -> @key(k).ekid()

  #---------
  
  _allocate_key_packets : () ->
    for key in @_all_keys()
      @_v_allocate_key_packet key

  #--------

  _all_keys : () -> [ @primary ].concat @subkeys
  self_sign_primary : (args, cb) -> @_v_self_sign_primary args, cb

  #--------

  sign_subkeys : ({asp}, cb) -> 
    err = null
    for subkey in @subkeys when not err?
      await @_v_sign_subkey {asp, subkey}, defer err
    cb err

  #--------

  sign : ({asp}, cb) ->
    await @self_sign_primary { asp }, defer err
    await @sign_subkeys { asp }, defer err unless err?
    cb err

  #--------

  merge_private : (eng2) ->
    err = null
    if not @_merge_1_private @primary, eng2.primary
      err = new Error "primary public key doesn't match private key"
    else if @subkeys.length isnt eng2.subkeys.length
      err = new Error "Different number of subkeys"
    else
      for key, i in @subkeys when not err?
        if not @_merge_1_private key, eng2.subkeys[i]
          err = new Error "Subkey #{i} doesn't match its public key"
    err

  #--------

  open_keys : ({asp, passphrase, tsenc}, cb) ->
    esc = make_esc cb, "Engine::open_keys"
    await @key(@primary).open {asp, tsenc, passphrase }, esc defer()
    for subkey in @subkeys
      await @key(subkey).open {asp, tsenc, passphrase }, esc defer()
    cb null

  #--------

  _merge_1_private : (k1, k2) ->
    if bufeq_secure(@ekid(k1), @ekid(k2))
      @_v_merge_private k1, k2
      true
    else
      false

#=================================================================

class PgpEngine extends Engine

  #--------
  
  constructor : ({primary, subkeys, userids}) ->
    super { primary, subkeys, userids }

  #--------

  key : (k) -> k._pgp
  
  #--------
  
  _v_allocate_key_packet : (key) ->
    unless key._pgp?
      key._pgp = new opkts.KeyMaterial { 
        key : key.key, 
        timestamp : key.lifespan.generated, 
        userid : @userids.get_openpgp() }

  #--------
  
  userid_packet : () ->
    @_uidp = new opkts.UserID @userids.get_openpgp() unless @_uidp?
    @_uidp

  #--------
  
  _v_self_sign_primary : ({asp}, cb) ->
    await @primary._pgp.self_sign_key { lifespan : @primary.lifespan, uidp : @userid_packet() }, defer err, @self_sig
    cb err

  #--------
  
  _v_sign_subkey : ({asp, subkey}, cb) ->
    await @primary._pgp.sign_subkey { subkey : subkey._pgp, lifespan : subkey.lifespan }, defer err, sig
    subkey._pgp_sig = sig
    cb err

  #--------

  _v_merge_private : (k1, k2) -> k1._pgp.merge_private k2._pgp

  #--------

  set_passphrase : (pp) ->
    @primary.passphrase = pp
    for k in @subkeys
      k.passphrase = pp

  #--------

  export_keys : (opts) ->
    packets = [ @primary._pgp.export_framed(opts), @userid_packet().write(), @self_sig ]
    opts.subkey = true
    for subkey in @subkeys
      packets.push subkey._pgp.export_framed(opts), subkey._pgp_sig
    buf = Buffer.concat(packets)
    mt = C.message_types
    type = if opts.private then mt.private_key else mt.public_key
    encode type, Buffer.concat(packets)

#=================================================================

class KeybaseEngine extends Engine

  constructor : ({primary, subkeys, userids}) ->
    super { primary, subkeys, userids }

  #--------

  key : (k) -> k._keybase

  #-----

  _check_can_sign : (keys,cb) ->
    err = null
    for k in keys when not err?
      err = new Error "cannot sign; don't have private key" unless k.key.can_sign()
    cb err

  #-----

  _v_allocate_key_packet : (key) ->
    unless key._keybase?
      key._keybase = new kpkts.KeyMaterial { 
        key : key.key, 
        timestamp : key.lifespan.generated }

  #-----

  _v_self_sign_primary : ({asp}, cb) ->
    esc = make_esc cb, "KeybaseEngine::_v_self_sign_primary"
    await @_check_can_sign [@primary], esc defer()
    @self_sigs = {}
    p = new kpkts.SelfSignKeybaseUsername { key_wrapper : @primary, @userids }
    await p.sign { asp, include_body : true }, esc defer @self_sigs.openpgp
    p = new kpkts.SelfSignPgpUserid { key_wrapper : @primary, @userids }
    await p.sign { asp, include_body : true }, esc defer @self_sigs.keybase
    cb null

  #-----

  _v_sign_subkey : ({asp, subkey}, cb) ->
    esc = make_esc cb, "KeybaseEngine::_v_sign_subkey"
    subkey._keybase_sigs = {}
    await @_check_can_sign [ @primary, subkey ], esc defer()
    p = new kpkts.SubkeySignature { @primary, subkey }
    await p.sign { asp, include_body : true }, esc defer subkey._keybase_sigs.fwd
    p = new kpkts.SubkeyReverseSignature { @primary, subkey }
    await p.sign { asp , include_body : true }, esc defer subkey._keybase_sigs.rev
    cb null

  #-----

  _v_merge_private : (k1, k2) -> k1._keybase.merge_private k2._keybase

  #-----

  export_private : ({tsenc,asp}, cb) ->
    ret = new kpkts.PrivateKeyBundle {}
    esc = make_esc cb, "KeybaseEngine::export_private"
    await @primary._keybase.export_private { tsenc, asp }, esc defer primary
    ret.primary =
      key : primary
      sigs :
        keybase : @self_sigs.keybase
        openpgp : @self_sigs.openpgp
    for k in @subkeys
      await k._keybase.export_private { tsenc, asp }, esc defer key
      ret.subkeys.push {
        key : key
        sigs :
          forward : k._keybase_sigs.fwd
          reverse : k._keybase_sigs.rev
      }
    cb null, ret.frame_packet()

  #-----

  export_public : ({asp}, cb) ->
    ret = new kpkts.PublicKeyBundle {}
    ret.primary =
      key : primary._keybase.export_public()
      sigs :
        keybase : @self_sigs.keybase
        openpgp : @self_sigs.openpgp
    ret.subkeys = for k in @subkeys
      {
        key : k._keybase.export_public()
        sigs :
          forward : k._keybase_sigs.fwd
          reverse : k._keybase_sigs.rev
      }
    cb ret.frame_packet()

#=================================================================

class KeyManager

  constructor : ({@primary, @subkeys, @userids, @armored_pgp_public, @armored_pgp_private}) ->
    @pgp = new PgpEngine { @primary, @subkeys, @userids }
    @keybase = new KeybaseEngine { @primary, @subkeys, @userids }
    @engines = [ @pgp, @keybase ]

  #========================
  # Public Interface

  # Generate a new key bunlde from scratch.  Make the given number
  # of subkeys.
  @generate : ({asp, nsubs, userid, nbits }, cb) ->
    userids = new UserIds { keybase : userid, openpgp : userid }
    generated = unix_time()
    esc = make_esc cb, "KeyManager::generate"
    asp.section "primary"
    await RSA.generate { asp, nbits: (nbits or K.key_defaults.primary.nbits) }, esc defer key
    lifespan = new Lifespan { generated, expire_in : K.key_defaults.primary.expire_in }
    primary = new Primary { key, lifespan }
    subkeys = []
    lifespan = new Lifespan { generated, expire_in : K.key_defaults.sub.expire_in }
    for i in [0...nsubs]
      asp.section "subkey #{i+1}"
      await RSA.generate { asp, nbits: (nbits or K.key_defaults.sub.nbits) }, esc defer key
      subkeys.push new Subkey { key, desc : "subkey #{i}", primary, lifespan }
    bundle = new KeyManager { primary, subkeys, userids }

    cb null, bundle

  #------------

  # The triplesec encoder will be primed (hopefully) with the output
  # of running Scrypt on the new passphrase, and the user's actual
  # salt.  We'll need this to encrypt server-stored key, or to derive
  # the key to encrypt a PGP secret key with s2k/AES-128-CFB.
  set_enc : (e) -> @tsenc = e

  #------------
 
  # Start from an armored PGP PUBLIC KEY BLOCK, and parse it into packets.
  # Also works for an armored PGP PRIVATE KEY BLOCK
  @import_from_armored_pgp : ({raw, asp, userid}, cb) ->
    [err,msg] = decode raw
    unless err?
      if not (msg.type in [C.message_types.public_key, C.message_types.private_key])
        err = new Error "Wanted a public or private key; got: #{msg.type}"
    bundle = null
    unless err?
      [err,packets] = parse msg.body
    unless err?
      kb = new KeyBlock packets
      await kb.process defer err
    unless err?
      userids = new UserIds { openpgp : kb.userid, keybase : userid }
      bundle = new KeyManager { 
        primary : KeyManager._wrap_pgp(Primary, kb.primary), 
        subkeys : (KeyManager._wrap_pgp(Subkey, k) for k in kb.subkeys), 
        armored_pgp_public : raw,
        userids }
    cb err, bundle

  #------------

  # Import from a base64-encoded-purepacked keybase key structure
  @import_from_packed_keybase : ({raw, asp}, cb) ->
    [err, {tag,body}] = unbox read_base64 raw
    unless err?
      if not tag in [K.packet_tags.public_key_bundle, K.packet_tags.private_key_bundle]
        err = new Error "Wanted a public or private key: #{tag}"
    unless err?
 
  # After importing the public portion of the key previously,
  # add the private portions with this call.  And again, verify
  # signatures.  And check that the public portions agree.
  merge_pgp_private : ({raw, asp}, cb) ->
    await KeyManager.import_from_armored_pgp { raw, asp }, defer err, b2
    err = @pgp.merge_private b2.pgp unless err?
    cb err

  #------------
 
  # Open the private PGP key with the given passphrase
  # (which is going to be different from our strong keybase passphrase).
  open_pgp : ({passphrase}, cb) ->
    await @pgp.open_keys { passphrase }, defer err
    cb err

  #-----
  
  # Open the private MPIs of the secret key, and check for sanity.
  # Use the given triplesec.Encryptor / password object.
  open_keybase : ({tsenc, asp}, cb) ->
    await @keybase.open_keys { tsenc, asp }, defer err
    cb err

  #-----
  
  # A private export consists of:
  #   1. The PGP public key block
  #   2. The keybase message (Public and private keys, triplesec'ed)
  export_private_to_server : ({tsenc, asp}, cb) ->
    pgp = @pgp.export_public()
    unless err?
      await @keybase.export_private { tsenc, asp }, defer err, keybase
    ret = if err? then null else { pgp, keybase : box(keybase).toString('base64') }
    cb err, ret

  #-----
  
  # Export to a PGP PRIVATE KEY BLOCK, stored in PGP format
  # We'll need to reencrypt with a derived key
  export_pgp_private_to_client : ({passphrase, asp, regen}, cb) ->
    passphrase = bufferify passphrase if passphrase?
    msg = @armored_pgp_private unless regen
    msg = @pgp.export_keys({private : true, passphrase}) unless msg?
    cb null, msg

  #-----
  
  # Export the PGP PUBLIC KEY BLOCK stored in PGP format
  # to the client...
  export_pgp_public : ({asp, regen}, cb) ->
    msg = @armored_pgp_public unless regen
    msg = @pgp.export_keys({private : false}) unless msg?
    cb null, msg

  #-----

  sign_pgp : ({asp}, cb) -> @pgp.sign { asp }, cb
  sign_keybase : ({asp}, cb) -> @keybase.sign { asp }, cb

  #-----

  sign : ({asp}, cb) ->
    asp?.section "sign"
    asp?.progress { what : "sign PGP" , total : 1, i : 0 }
    await @sign_pgp     { asp }, defer err
    asp?.progress { what : "sign PGP" , total : 1, i : 1 }
    asp?.progress { what : "sign keybase" , total : 1, i : 0 }
    await @sign_keybase { asp }, defer err unless err?
    asp?.progress { what : "sign keybase" , total : 1, i : 1 }
    cb err
  
  # /Public Interface
  #========================
  
  _apply_to_engines : ({args, meth}, cb) ->
    err = null
    for e in @engines when not err
      await meth.call e, args, defer(err)
    cb err

  #----------

  # @param {openpgp.KeyMaterial} kmp An openpgp KeyMaterial packet
  @_wrap_pgp : (klass, kmp) ->
    new klass { 
      key : kmp.key, 
      lifespan : new Lifespan { generated : kmp.timestamp }
      _pgp : kmp
    }

  #----------

  to_openpgp_packet : ( { tsec, passphrase } ) ->

  to_keybase_packet : ( { tsec, passphrase } ) ->

#=================================================================

exports.KeyManager = KeyManager
exports.Encryption = Encryption