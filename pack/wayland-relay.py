# wayland socket relay：双向转发字节流与 SCM_RIGHTS 文件描述符
# 用法: python3 wayland-relay.py <监听路径> <目标socket>
import os
import socket
import sys
import threading

LISTEN = os.path.abspath(sys.argv[1])
TARGET = os.path.abspath(sys.argv[2])


def pump(src, dst):
    while True:
        data, anc, _flags, _addr = src.recvmsg(65536, socket.CMSG_SPACE(64 * 4))
        if not data and not anc:
            break
        if anc:
            dst.sendmsg([data], anc)
            # fd 已随 sendmsg 发出，关闭本地副本防泄漏
            for _level, ctype, fdata in anc:
                if ctype == socket.SCM_RIGHTS:
                    for fd in memoryview(fdata).cast("i"):
                        try:
                            os.close(fd)
                        except OSError:
                            pass
        else:
            dst.sendall(data)


def handle(client):
    try:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.connect(TARGET)
    except OSError:
        client.close()
        return
    t1 = threading.Thread(target=pump, args=(client, server), daemon=True)
    t2 = threading.Thread(target=pump, args=(server, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    server.close()


ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    os.unlink(LISTEN)
except FileNotFoundError:
    pass
# 监听目录可能尚不存在（如 %t/pot-wayland），先建
os.makedirs(os.path.dirname(LISTEN), exist_ok=True)
ls.bind(LISTEN)
ls.listen(16)
print(f"relay {LISTEN} -> {TARGET}", flush=True)
while True:
    c, _ = ls.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
