class_name Hkdf
extends RefCounted
## HKDF-SHA256 (RFC 5869) поверх Crypto.hmac_digest. Как в C++ (OpenSSL EVP_PKEY_HKDF без соли): соль = 32 нулевых байта.

const HASH_LEN := 32


static func hmac(key: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256, key, msg)


static func derive(secret: PackedByteArray, info: PackedByteArray, length: int = 32) -> PackedByteArray:
	var salt := PackedByteArray()
	salt.resize(HASH_LEN)
	var prk := hmac(salt, secret)                       # Extract
	var out := PackedByteArray()
	var t := PackedByteArray()
	var i := 1
	while out.size() < length:                          # Expand
		var block := t.duplicate()
		block.append_array(info)
		block.append(i)
		t = hmac(prk, block)
		out.append_array(t)
		i += 1
	return out.slice(0, length)
