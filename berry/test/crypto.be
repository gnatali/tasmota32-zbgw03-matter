# Module `crypto` de test : meme API que Tasmota, sur les fonctions natives BearSSL
# de l'interpreteur de test (_aes_cbc, _gcm, _hmac_sha256, _md5, _random)
var crypto = module("crypto")

class AES_CBC
  static def encrypt1(k, iv, d)  return _aes_cbc(true, k, iv, d)  end
  static def decrypt1(k, iv, d)  return _aes_cbc(false, k, iv, d)  end
end

class AES_GCM
  var k, iv, aad, t, used
  def init(k, iv, aad)
    if size(k) != 16 && size(k) != 32  raise "value_error", "Key size must be 16 or 32 bytes"  end
    self.k = k  self.iv = iv  self.aad = aad
  end
  def _run(enc, d)
    if self.used  raise "test_error", "AES_GCM de test : un seul appel par instance"  end
    self.used = true
    var r = _gcm(enc, self.k, self.iv, self.aad, d)
    self.t = r[1]
    return r[0]
  end
  def encrypt(d)  return self._run(true, d)  end
  def decrypt(d)  return self._run(false, d)  end
  def tag()  return self.t  end
end

class HMAC_SHA256
  var k, buf
  def init(k)  self.k = k  self.buf = bytes()  end
  def update(d)  self.buf .. d  return self  end
  def out()  return _hmac_sha256(self.k, self.buf)  end
end

class MD5
  var buf
  def init()  self.buf = bytes()  end
  def update(d)  self.buf .. d  return self  end
  def finish()  return _md5(self.buf)  end
end

crypto.AES_CBC = AES_CBC
crypto.AES_GCM = AES_GCM
crypto.HMAC_SHA256 = HMAC_SHA256
crypto.MD5 = MD5
crypto.random = def (n) return _random(n) end

return crypto
