import socket
try:
    s = socket.create_connection(("2001:67c:4e8:f002::a", 443), 6)
    s.close()
    print("v6ok DC2")
except Exception as e:
    print("v6fail:", e)
