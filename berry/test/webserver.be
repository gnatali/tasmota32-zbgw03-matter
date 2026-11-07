# Module `webserver` de test : routes enregistrees, page rendue dans un tampon, arguments
# fournis par le harnais (commande HTTP). Meme API que le module de Tasmota pour le driver.
var webserver = module("webserver")
webserver.HTTP_GET = 1
webserver.HTTP_POST = 2
webserver.BUTTON_CONFIGURATION = 0
webserver._routes = {}
webserver._args = {}
webserver._out = []
webserver.state = def () return 1 end
webserver.on = def (prefix, f, method)
  webserver._routes[prefix + ":" + (method == 2 ? "POST" : "GET")] = f
end
webserver.check_privileged_access = def () return true end
webserver.content_start = def (t) webserver._out.push("<title>" + t + "</title>") end
webserver.content_send_style = def () end
webserver.content_send = def (s) webserver._out.push(s) end
webserver.content_button = def (b) end
webserver.content_stop = def () end
webserver.redirect = def (u) webserver._out.push("REDIRECT " + u) end
webserver.has_arg = def (n) return webserver._args.contains(n) end
webserver.arg = def (n) return webserver._args.find(n) end
webserver.html_escape = def (s)
  import string
  s = string.replace(s, "&", "&amp;")
  s = string.replace(s, "<", "&lt;")
  s = string.replace(s, ">", "&gt;")
  s = string.replace(s, "'", "&#39;")
  return string.replace(s, "\"", "&quot;")
end
return webserver
