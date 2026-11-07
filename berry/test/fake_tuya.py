"""Faux appareils Tuya (protocoles 3.3, 3.4, 3.5 et passerelle Zigbee 3.3) pour les tests.

Construit sur les primitives de TinyTuya (pack/unpack, AESCipher) : c'est la reference
independante contre laquelle le driver Berry est teste.
"""
import json
import os
import struct
import hmac
from hashlib import sha256

from tinytuya.core.message_helper import pack_message, unpack_message, parse_header, TuyaMessage
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core import header as H
from tinytuya.core import command_types as CT


def _hmac(k, d):
    return hmac.new(k, d, sha256).digest()


class FakeDevice:
    def __init__(self, dev_id, key, version, dps=None, children=None):
        self.id = dev_id
        self.real_key = key.encode() if isinstance(key, str) else key
        self.key = self.real_key
        self.version = version
        self.dps = dict(dps or {})
        self.children = {cid: dict(d) for cid, d in (children or {}).items()}
        self.seq = 100
        self.rx = b""
        self.remote_nonce = None
        self.client_nonce = None
        self.log = []          # (cmd, json) recus apres dechiffrement
        self.hb = 0

    @property
    def vbytes(self):
        return ("%.1f" % self.version).encode()

    def reset_session(self):
        self.key = self.real_key
        self.rx = b""

    # ---------- reception ----------
    def feed(self, data):
        """Recoit des octets du client, renvoie la liste des trames de reponse."""
        self.rx += data
        out = []
        while True:
            if len(self.rx) < 4:
                break
            try:
                hdr = parse_header(self.rx)
            except Exception:
                raise
            if len(self.rx) < hdr.total_length:
                break
            frame, self.rx = self.rx[:hdr.total_length], self.rx[hdr.total_length:]
            out += self.handle(frame)
        return out

    def handle(self, frame):
        hk = self.key if self.version >= 3.4 else None
        msg = unpack_message(frame, hmac_key=hk, no_retcode=True)
        assert msg.crc_good, "CRC/HMAC/tag invalide cote appareil (cmd %d)" % msg.cmd
        payload = msg.payload
        cipher = AESCipher(self.key)
        if self.version == 3.4:
            payload = cipher.decrypt(payload, False, decode_text=False)
        if self.version >= 3.4:
            if payload.startswith(self.vbytes):
                payload = payload[15:]
        else:
            if payload.startswith(self.vbytes):
                payload = payload[15:]
            if payload:
                payload = cipher.decrypt(payload, False, decode_text=False)
        cmd = msg.cmd
        if cmd == CT.SESS_KEY_NEG_START:
            return self.nego_start(payload)
        if cmd == CT.SESS_KEY_NEG_FINISH:
            return self.nego_finish(payload)
        j = json.loads(payload.decode()) if payload else {}
        self.log.append((cmd, j))
        if cmd == CT.HEART_BEAT:
            self.hb += 1
            return [self.reply(CT.HEART_BEAT, b"", header=False)]
        if cmd in (CT.DP_QUERY, CT.DP_QUERY_NEW):
            cid = j.get("cid")
            if cid is not None:
                body = {"cid": cid, "dps": self.children[cid]}
            else:
                body = {"devId": self.id, "dps": self.dps}
            return [self.reply(cmd, json.dumps(body).encode(), header=False)]
        if cmd in (CT.CONTROL, CT.CONTROL_NEW):
            data = j.get("data", j)
            dps = data["dps"]
            cid = data.get("cid")
            if cid is not None:
                self.children[cid].update(dps)
                push = {"cid": cid, "dps": dps, "t": 1}
            else:
                self.dps.update(dps)
                push = {"devId": self.id, "dps": dps, "t": 1}
                if self.version >= 3.4:
                    push = {"protocol": 4, "t": 1, "data": {"dps": dps}}
            return [self.reply(cmd, b"", header=False), self.push(push)]
        return []

    # ---------- emission ----------
    def push(self, obj):
        """Trame de mise a jour spontanee (STATUS 0x08)."""
        return self.reply(CT.STATUS, json.dumps(obj).encode(), header=True)

    def reply(self, cmd, payload, header):
        self.seq += 1
        if self.version >= 3.5:
            plain = (self.vbytes + b"\0" * 12 if header and payload else b"") + payload
            m = TuyaMessage(self.seq, cmd, 0, plain, 0, True, H.PREFIX_6699_VALUE, True)
            return pack_message(m, hmac_key=self.key)
        cipher = AESCipher(self.key)
        if self.version == 3.4:
            plain = (self.vbytes + b"\0" * 12 if header and payload else b"") + payload
            body = struct.pack(">I", 0) + (cipher.encrypt(plain, False) if plain else b"")
            m = TuyaMessage(self.seq, cmd, 0, body, 0, True, H.PREFIX_55AA_VALUE, False)
            return pack_message(m, hmac_key=self.key)
        body = cipher.encrypt(payload, False) if payload else b""
        if header and payload:
            body = self.vbytes + b"\0" * 12 + body
        m = TuyaMessage(self.seq, cmd, 0, struct.pack(">I", 0) + body, 0, True, H.PREFIX_55AA_VALUE, False)
        return pack_message(m)

    # ---------- negociation de cle de session ----------
    def nego_start(self, client_nonce):
        assert len(client_nonce) == 16
        self.client_nonce = client_nonce
        self.remote_nonce = os.urandom(16)
        resp = self.remote_nonce + _hmac(self.real_key, client_nonce)
        self.seq += 1
        if self.version >= 3.5:
            m = TuyaMessage(self.seq, CT.SESS_KEY_NEG_RESP, 0, resp, 0, True, H.PREFIX_6699_VALUE, True)
            return [pack_message(m, hmac_key=self.real_key)]
        body = struct.pack(">I", 0) + AESCipher(self.real_key).encrypt(resp, False)
        m = TuyaMessage(self.seq, CT.SESS_KEY_NEG_RESP, 0, body, 0, True, H.PREFIX_55AA_VALUE, False)
        return [pack_message(m, hmac_key=self.real_key)]

    def nego_finish(self, payload):
        assert payload[:32] == _hmac(self.real_key, self.remote_nonce), "HMAC de fin de negociation invalide"
        x = bytes(a ^ b for a, b in zip(self.client_nonce, self.remote_nonce))
        c = AESCipher(self.real_key)
        if self.version == 3.4:
            self.key = c.encrypt(x, False, pad=False)
        else:
            self.key = c.encrypt(x, use_base64=False, pad=False, iv=self.client_nonce[:12])[12:28]
        self.log.append(("session", self.key.hex()))
        return []


# ---- annonces UDP (decouverte), comme les envoient les appareils -----------------------------
from tinytuya.core.udp_helper import udpkey, decrypt_udp  # noqa: E402


def udp_broadcast(version, info):
    """Annonce UDP d'un appareil : 3.1 en clair (port 6666), 3.3 en AES-ECB (6667),
    3.5 en trame 6699 AES-GCM (7000). Verifiee avec decrypt_udp() de TinyTuya."""
    js = json.dumps(info).encode()
    if version == 3.1:
        pkt = pack_message(TuyaMessage(0, 0, None, b"\0\0\0\0" + js, 0, True, H.PREFIX_55AA_VALUE, None))
    elif version == 3.3:
        enc = AESCipher(udpkey).encrypt(js, use_base64=False, pad=True)
        pkt = pack_message(TuyaMessage(0, 0x13, None, b"\0\0\0\0" + enc, 0, True, H.PREFIX_55AA_VALUE, None))
    else:
        pkt = pack_message(TuyaMessage(0, 0x23, 0, js, 0, True, H.PREFIX_6699_VALUE, True), hmac_key=udpkey)
    assert json.loads(decrypt_udp(pkt)) == info, "annonce UDP non reconnue par TinyTuya"
    return pkt
