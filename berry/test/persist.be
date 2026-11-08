# Test `persist` module: like Tasmota's, `import persist` gives an instance whose attributes are
# the persisted values (setmember / member), with find() and save(); kept in memory, save()
# prints the content (PERSIST ...).
var persist = module("persist")
persist.init = def (m)
  class Persist
    var _p
    def init()  self._p = {}  end
    def find(k, d)  return self._p.find(k, d)  end
    def has(k)  return self._p.contains(k)  end
    def save()
      import json
      print("PERSIST " + json.dump(self._p))
    end
    def setmember(k, v)  self._p[k] = v  end
    def member(k)  return self._p.find(k)  end
  end
  return Persist()
end
return persist
