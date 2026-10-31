"""Request ACPI power-off; the owner separately verifies actual process exit."""
import json
import socket

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
    client.connect('/run/shm/monitor.sock')
    client.recv(4096)
    client.sendall(b'system_powerdown\n')
    response = client.recv(8192)
    if b'Error' in response:
        raise RuntimeError('QEMU rejected the ACPI power-off request')
print(json.dumps({'PoweroffRequested': True}))
