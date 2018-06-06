module type S = Digestif_sig.S

module Bi = Digestif_bigstring
module By = Digestif_bytes
module Conv = Digestif_conv
module Native = Rakia_native

module type Foreign = sig
  open Native

  type kind

  module Bigstring:
  sig
    val init: ctx -> unit
    val update: ctx -> ba -> int -> int -> unit
    val finalize: ctx -> ba -> int -> unit
  end

  module Bytes:
  sig
    val init: ctx -> unit
    val update: ctx -> st -> int -> int -> unit
    val finalize: ctx -> st -> int -> unit
  end

  val ctx_size: unit -> int
end

module type Desc =
sig
  val block_size: int
  val digest_size: int
end

module Unsafe (F : Foreign) (D : Desc) = struct
  let block_size = D.block_size
  and digest_size = D.digest_size
  and ctx_size = F.ctx_size ()

  let init () =
    let t = By.create ctx_size in
    ( F.Bytes.init t; t )

  let empty = Bytes.create ctx_size
  let () = F.Bytes.init empty

  let unsafe_feed_bytes t ?off ?len buf =
    let off, len = match off, len with
      | Some off, Some len -> off, len
      | Some off, None -> off, By.length buf - off
      | None, Some len -> 0, len
      | None, None -> 0, By.length buf in
    F.Bytes.update t buf off len

  let unsafe_feed_string t ?off ?len buf =
    unsafe_feed_bytes t ?off ?len (Bytes.unsafe_of_string buf)

  let unsafe_feed_bigstring t ?off ?len buf =
    let off, len = match off, len with
      | Some off, Some len -> off, len
      | Some off, None -> off, Bi.length buf - off
      | None, Some len -> 0, len
      | None, None -> 0, Bi.length buf in
    F.Bigstring.update t buf off len

  let unsafe_get t =
    let res = By.create digest_size in
    ( F.Bytes.finalize t res 0; res )
end

module Core (F : Foreign) (D : Desc) = struct
  type t = string
  type ctx = Native.ctx
  type kind = F.kind

  include Unsafe (F) (D)
  include Conv.Make (D)

  let eq = String.equal
  let neq a b = not (eq a b)
  let compare = String.compare

  let get t =
    let t = Native.dup t in
    unsafe_get t |> Bytes.unsafe_to_string

  let feed_bytes t ?off ?len buf =
    let t = Native.dup t in
    ( unsafe_feed_bytes t ?off ?len buf; t )

  let feed_string t ?off ?len buf =
    let t = Native.dup t in
    ( unsafe_feed_string t ?off ?len buf; t )

  let feed_bigstring t ?off ?len buf =
    let t = Native.dup t in
    ( unsafe_feed_bigstring t ?off ?len buf; t )

  let feedi_bytes t iter =
    let t = Native.dup t in
    let feed buf = unsafe_feed_bytes t buf in
    ( iter feed; t )

  let feedi_string t iter =
    let t = Native.dup t in
    let feed buf = unsafe_feed_string t buf in
    ( iter feed; t )

  let feedi_bigstring t iter =
    let t = Native.dup t in
    let feed buf = unsafe_feed_bigstring t buf in
    ( iter feed; t )

  let digest_bytes ?off ?len buf = feed_bytes empty ?off ?len buf |> get
  let digest_string ?off ?len buf = feed_string empty ?off ?len buf |> get
  let digest_bigstring ?off ?len buf = feed_bigstring empty ?off ?len buf |> get

  let digesti_bytes iter = feedi_bytes empty iter |> get
  let digesti_string iter = feedi_string empty iter |> get
  let digesti_bigstring iter = feedi_bigstring empty iter |> get

  let digestv_bytes lst = digesti_bytes (fun f -> List.iter f lst)
  let digestv_string lst = digesti_string (fun f -> List.iter f lst)
  let digestv_bigstring lst = digesti_bigstring (fun f -> List.iter f lst)
end

module Make (F : Foreign) (D : Desc) = struct
  include Core (F) (D)

  let bytes_opad = By.init block_size (fun _ -> '\x5c')
  let bytes_ipad = By.init block_size (fun _ -> '\x36')

  let rec norm_bytes key =
    match Pervasives.compare (By.length key) block_size with
    | 1  -> norm_bytes (Bytes.unsafe_of_string (digest_bytes key))
    | -1 -> By.rpad key block_size '\000'
    | _  -> key

  let bigstring_opad = Bi.init block_size (fun _ -> '\x5c')
  let bigstring_ipad = Bi.init block_size (fun _ -> '\x36')

  let norm_bigstring key =
    let key = Bi.to_string key in
    let res0 = norm_bytes (Bytes.unsafe_of_string key) in
    let res1 = Bi.create (By.length res0) in
    Bi.blit_from_bytes res0 0 res1 0 (By.length res0); res1

  let hmaci_bytes ~key iter =
    let key = norm_bytes key in
    let outer = Native.XOR.Bytes.xor key bytes_opad in
    let inner = Native.XOR.Bytes.xor key bytes_ipad in
    let res = digesti_bytes (fun f -> f inner; iter f) in
    digesti_bytes (fun f -> f outer; f (Bytes.unsafe_of_string res))

  let hmaci_string ~key iter =
    let key = norm_bytes (Bytes.unsafe_of_string key) in
    (* XXX(dinosaure): safe, [rpad] and [digest] have a read-only access. *)
    let outer = Native.XOR.Bytes.xor key bytes_opad in
    let inner = Native.XOR.Bytes.xor key bytes_ipad in
    let ctx = feed_bytes empty inner in
    let res = feedi_string ctx iter |> get in
    let ctx = feed_bytes empty outer in
    feed_string ctx (res :> string) |> get

  let hmaci_bigstring ~key iter =
    let key = norm_bigstring key in
    let outer = Native.XOR.Bigstring.xor key bigstring_opad in
    let inner = Native.XOR.Bigstring.xor key bigstring_ipad in
    let res = digesti_bigstring (fun f -> f inner; iter f) in
    let ctx = feed_bigstring empty outer in
    feed_string ctx (res :> string) |> get

  let hmac_bytes ~key ?off ?len buf =
    let buf = match off, len with
      | Some off, Some len -> Bytes.sub buf off len
      | Some off, None -> Bytes.sub buf off (Bytes.length buf - off)
      | None, Some len -> Bytes.sub buf 0 len
      | None, None -> buf in
    hmaci_bytes ~key (fun f -> f buf)

  let hmac_string ~key ?off ?len buf =
    let buf = match off, len with
      | Some off, Some len -> String.sub buf off len
      | Some off, None -> String.sub buf off (String.length buf - off)
      | None, Some len -> String.sub buf 0 len
      | None, None -> buf in
    hmaci_string ~key (fun f -> f buf)

  let hmac_bigstring ~key ?off ?len buf =
    let buf = match off, len with
      | Some off, Some len -> Bi.sub buf off len
      | Some off, None -> Bi.sub buf off (Bi.length buf - off)
      | None, Some len -> Bi.sub buf 0 len
      | None, None -> buf in
    hmaci_bigstring ~key (fun f -> f buf)

  let hmacv_bytes ~key bufs = hmaci_bytes ~key (fun f -> List.iter f bufs)
  let hmacv_string ~key bufs = hmaci_string ~key (fun f -> List.iter f bufs)
  let hmacv_bigstring ~key bufs = hmaci_bigstring ~key (fun f -> List.iter f bufs)
end

(* XXX(dinosaure): this interface provide a new function to set digest size and
   key. See #20. *)
module type Foreign_BLAKE2 = sig
  open Native

  type kind

  module Bigstring :
  sig
    val init: ctx -> unit
    val update: ctx -> ba -> int -> int -> unit
    val finalize: ctx -> ba -> int -> unit
    val with_outlen_and_key: ctx -> int -> ba -> int -> int -> unit
  end

  module Bytes :
  sig
    val init: ctx -> unit
    val update: ctx -> st -> int -> int -> unit
    val finalize: ctx -> st -> int -> unit
    val with_outlen_and_key: ctx -> int -> st -> int -> int -> unit
  end

  val ctx_size: unit -> int
  val key_size: unit -> int
  val digest_size: ctx -> int
end

module Core_BLAKE2 (F : Foreign_BLAKE2) (D : Desc) = Core (F) (D)

module Make_BLAKE2 (F : Foreign_BLAKE2) (D : Desc) = struct
  include Core_BLAKE2 (F) (D)

  let key_size = F.key_size ()

  let hmaci_bytes ~key iter : t =
    if By.length key > key_size
    then invalid_arg "BLAKE2{S,B}.hmaci_bytes: invalid key";

    let ctx = By.create ctx_size in
    F.Bytes.with_outlen_and_key ctx digest_size key 0 (By.length key);
    feedi_bytes ctx iter |> get

  let hmaci_string ~key iter =
    if String.length key > key_size
    then invalid_arg "BLAKE2{S,B}.hmaci_string: invalid key";

    let ctx = By.create ctx_size in
    F.Bytes.with_outlen_and_key ctx digest_size (Bytes.unsafe_of_string key) 0 (String.length key);
    feedi_string ctx iter |> get

  let hmaci_bigstring ~key iter =
    if Bi.length key > key_size
    then invalid_arg "BLAKE2{S,B}.hmaci_bigstring: invalid key";

    let ctx = By.create ctx_size in
    F.Bigstring.with_outlen_and_key ctx digest_size key 0 (Bi.length key);
    feedi_bigstring ctx iter |> get

  let hmac_bytes ~key ?off ?len buf : t =
    let buf = match off, len with
      | Some off, Some len -> By.sub buf off len
      | Some off, None -> By.sub buf off (Bytes.length buf - off)
      | None, Some len -> By.sub buf 0 len
      | None, None -> buf in
    hmaci_bytes ~key (fun f -> f buf)

  let hmac_string ~key ?off ?len buf =
    let buf = match off, len with
      | Some off, Some len -> String.sub buf off len
      | Some off, None -> String.sub buf off (String.length buf - off)
      | None, Some len -> String.sub buf 0 len
      | None, None -> buf in
    hmaci_string ~key (fun f -> f buf)

  let hmac_bigstring ~key ?off ?len buf =
    let buf = match off, len with
      | Some off, Some len -> Bi.sub buf off len
      | Some off, None -> Bi.sub buf off (Bi.length buf - off)
      | None, Some len -> Bi.sub buf 0 len
      | None, None -> buf in
    hmaci_bigstring ~key (fun f -> f buf)

  let hmacv_bytes ~key bufs = hmaci_bytes ~key (fun f -> List.iter f bufs)
  let hmacv_string ~key bufs = hmaci_string ~key (fun f -> List.iter f bufs)
  let hmacv_bigstring ~key bufs = hmaci_bigstring ~key (fun f -> List.iter f bufs)
end

module MD5 : S with type kind = [ `MD5 ] = Make (Native.MD5) (struct let (digest_size, block_size) = (16, 64) end)
module SHA1 : S with type kind = [ `SHA1 ] = Make (Native.SHA1) (struct let (digest_size, block_size) = (20, 64) end)
module SHA224 : S with type kind = [ `SHA224 ] = Make (Native.SHA224) (struct let (digest_size, block_size) = (28, 64) end)
module SHA256 : S with type kind = [ `SHA256 ] = Make (Native.SHA256) (struct let (digest_size, block_size) = (32, 64) end)
module SHA384 : S with type kind = [ `SHA384 ] = Make (Native.SHA384) (struct let (digest_size, block_size) = (48, 128) end)
module SHA512 : S with type kind = [ `SHA512 ] = Make (Native.SHA512) (struct let (digest_size, block_size) = (64, 128) end)
module BLAKE2B : S with type kind = [ `BLAKE2B ] = Make_BLAKE2(Native.BLAKE2B) (struct let (digest_size, block_size) = (64, 128) end)
module BLAKE2S : S with type kind = [ `BLAKE2S ] = Make_BLAKE2(Native.BLAKE2S) (struct let (digest_size, block_size) = (32, 64) end)
module RMD160 : S with type kind = [ `RMD160 ] = Make (Native.RMD160) (struct let (digest_size, block_size) = (20, 64) end)

module Make_BLAKE2B (D : sig val digest_size : int end) : S with type kind = [ `BLAKE2B ] =
struct
  include Make_BLAKE2(Native.BLAKE2B)(struct let (digest_size, block_size) = (D.digest_size, 128) end)
end

module Make_BLAKE2S (D : sig val digest_size : int end) : S with type kind = [ `BLAKE2S ] =
struct
  include Make_BLAKE2(Native.BLAKE2S)(struct let (digest_size, block_size) = (D.digest_size, 64) end)
end

include Digestif_hash

type blake2b = (module S with type kind = [ `BLAKE2B ])
type blake2s = (module S with type kind = [ `BLAKE2S ])

let module_of : type k. k hash -> (module S with type kind = k) = fun hash ->
  let b2b : (int, blake2b) Hashtbl.t = Hashtbl.create 13 in
  let b2s : (int, blake2s) Hashtbl.t = Hashtbl.create 13 in
  match hash with
  | Digestif_sig.MD5     -> (module MD5)
  | Digestif_sig.SHA1    -> (module SHA1)
  | Digestif_sig.RMD160  -> (module RMD160)
  | Digestif_sig.SHA224  -> (module SHA224)
  | Digestif_sig.SHA256  -> (module SHA256)
  | Digestif_sig.SHA384  -> (module SHA384)
  | Digestif_sig.SHA512  -> (module SHA512)
  | Digestif_sig.BLAKE2B digest_size -> begin
      match Hashtbl.find b2b digest_size with
      | exception Not_found ->
        let m : (module S with type kind = [ `BLAKE2B ]) =
          (module Make_BLAKE2B(struct let digest_size = digest_size end)
             : S with type kind = [ `BLAKE2B ]) in
        Hashtbl.replace b2b digest_size m ; m
      | m -> m
    end
  | Digestif_sig.BLAKE2S digest_size -> begin
      match Hashtbl.find b2s digest_size with
      | exception Not_found ->
        let m =
          (module Make_BLAKE2S(struct let digest_size = digest_size end)
             : S with type kind = [ `BLAKE2S ]) in
        Hashtbl.replace b2s digest_size m ; m
      | m -> m
    end

type 'kind t = string
type bigstring = Digestif_sig.bigstring

type 'a pp = 'a Digestif_sig.pp
type 'a iter = 'a Digestif_sig.iter
type 'a equal = 'a Digestif_sig.equal
type 'a compare = 'a Digestif_sig.compare

let digesti_bytes
  : type k. k hash -> Bytes.t iter -> k t
  = fun hash iter ->
    let module H = (val (module_of hash)) in
    ((H.digesti_bytes iter :> string) : H.kind t)

let digesti_string
  : type k. k hash -> String.t iter -> k t
  = fun hash iter ->
    let module H = (val (module_of hash)) in
    ((H.digesti_string iter :> string) : H.kind t)

let digesti_bigstring
  : type k. k hash -> bigstring iter -> k t
  = fun hash iter ->
    let module H = (val (module_of hash)) in
    ((H.digesti_bigstring iter :> string) : H.kind t)

let hmaci_bytes
  : type k. k hash -> key:Bytes.t -> Bytes.t iter -> k t
  = fun hash ~key iter ->
    let module H = (val (module_of hash)) in
    ((H.hmaci_bytes ~key iter :> string) : H.kind t)

let hmaci_string
  : type k. k hash -> key:String.t -> String.t iter -> k t
  = fun hash ~key iter ->
    let module H = (val (module_of hash)) in
    ((H.hmaci_string ~key iter :> string) : H.kind t)

let hmaci_bigstring
  : type k. k hash -> key:bigstring -> bigstring iter -> k t
  = fun hash ~key iter ->
    let module H = (val (module_of hash)) in
    ((H.hmaci_bigstring ~key iter :> string) : H.kind t)

(* XXX(dinosaure): unsafe part to avoid overhead. *)

let compare
  : type k. k hash -> k t -> k t -> int
  = fun hash a b ->
    let module H = (val (module_of hash)) in
    let unsafe : 'k t -> H.t = Obj.magic in
    H.compare (unsafe a) (unsafe b)

let eq
  : type k. k hash -> k t equal
  = fun hash a b ->
    let module H = (val (module_of hash)) in
    let unsafe : 'k t -> H.t = Obj.magic in
    H.eq (unsafe a) (unsafe b)

let neq
  : type k. k hash -> k t equal
  = fun hash a b ->
    let module H = (val (module_of hash)) in
    let unsafe : 'k t -> H.t = Obj.magic in
    H.neq (unsafe a) (unsafe b)

let pp
  : type k. k hash -> k t pp
  = fun hash ppf t  ->
    let module H = (val (module_of hash)) in
    let unsafe : 'k t -> H.t = Obj.magic in
    H.pp ppf (unsafe t)

let of_hex
  : type k. k hash -> string -> k t
  = fun hash hex ->
    let module H = (val (module_of hash)) in
    (H.of_hex hex :> string)

let to_hex
  : type k. k hash -> k t -> string
  = fun hash t ->
    let module H = (val (module_of hash)) in
    let unsafe : 'k t -> H.t = Obj.magic in
    (H.to_hex (unsafe t))
