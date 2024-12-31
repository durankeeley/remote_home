#!/bin/sh

# Enabling Alpine Linux Community Repository
echo "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/community/" >> /etc/apk/repositories
apk update

# Install OpenVPN and Easy-RSA
apk add openvpn easy-rsa iptables iptables-openrc bind-tools

# Enable openvpn at system startup
rc-update add openvpn default

# Ensure TUN device module is loaded
modprobe tun
echo "tun" >> /etc/modules-load.d/tun.conf

# Enable IPv4 forwarding
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/ipv4.conf
sysctl -p /etc/sysctl.d/ipv4.conf

# Persist rules across reboots
service iptables save
rc-update add iptables

# Grab all IPv4 addresses except loopback
number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
echo "Which IPv4 address should be used?"
ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' \
   | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '

read -p "IPv4 address [1]: " ip_number
until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
    echo "$ip_number: invalid selection."
    read -p "IPv4 address [1]: " ip_number
done
[[ -z "$ip_number" ]] && ip_number="1"

ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' \
     | cut -d '/' -f 1 \
     | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' \
     | sed -n "${ip_number}p")

# Now find which adapter has that IP:
adapter=$(
  ip -4 addr \
    | grep -B2 "inet $ip" \
    | grep -E '^[0-9]+:' \
    | head -1 \
    | sed -r 's/^[0-9]+:\s+([^:]+):.*/\1/'
)

echo "Detected adapter for $ip is: $adapter"

#Find DNS server from that IP Address
dns_server=$(dig -b $ip google.com | awk '/SERVER:/ { split($3, a, "#"); print a[1] }')

# NAT rule for traffic from the VPN subnet to the outside interface (eth0)
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $adapter -j MASQUERADE

# Allow forwarding between the tun0 and eth0 interfaces
iptables -A FORWARD -i tun0 -o $adapter -j ACCEPT
iptables -A FORWARD -i $adapter -o tun0 -j ACCEPT
 
# Set protocol & port
protocol=tcp
port=1194

# Ask for the first client name
echo "Enter a name for the first client:"
read -p "Name [client]: " unsanitized_client
client=$(echo "$unsanitized_client" | sed 's/[^0-9A-Za-z_-]/_/g')
[ -z "$client" ] && client="client"

# Prepare Easy-RSA
cd /usr/share/easy-rsa || exit 1
./easyrsa --batch init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch --days=3650 build-server-full server nopass
./easyrsa --batch --days=3650 build-client-full "$client" nopass
./easyrsa --batch --days=3650 gen-crl
./easyrsa gen-dh

# Create OpenVPN server directory and copy files
mkdir -p /etc/openvpn/server
cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem pki/dh.pem /etc/openvpn/server

# Protect the server folder
chmod o+x /etc/openvpn/server/

# Generate the TLS-crypt key
openvpn --genkey secret /etc/openvpn/server/tc.key

# Create the OpenVPN server.conf
cat <<EOF > /etc/openvpn/openvpn.conf
local $ip
port $port
proto $protocol
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
auth SHA512
tls-crypt /etc/openvpn/server/tc.key
topology subnet
server 10.8.0.0 255.255.255.0

push "redirect-gateway def1 bypass-dhcp"
push "block-outside-dns"
push "dhcp-option DNS $dns_server"

keepalive 10 120
user nobody
group nogroup

persist-key
persist-tun
verb 3

crl-verify /etc/openvpn/server/crl.pem
EOF

# Create a base client config file
cat <<EOF > /etc/openvpn/server/client-common.txt
client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3
EOF

# Function to generate a new client .ovpn
new_client () {
    local client_name="$1"
    local outdir="$2"

    [ -z "$client_name" ] && client_name="client"
    [ -z "$outdir" ] && outdir="$HOME"

    {
        cat /etc/openvpn/server/client-common.txt
        echo "<ca>"
        cat /etc/openvpn/server/ca.crt
        echo "</ca>"
        echo "<cert>"
        # Only include the certificate portion (BEGIN CERTIFICATE -> END CERTIFICATE)
        sed -ne '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' \
            /usr/share/easy-rsa/pki/issued/"$client_name".crt
        echo "</cert>"
        echo "<key>"
        cat /usr/share/easy-rsa/pki/private/"$client_name".key
        echo "</key>"
        echo "<tls-crypt>"
        cat /etc/openvpn/server/tc.key
        echo "</tls-crypt>"
    } > "$outdir/$client_name.ovpn"
}

# Generate the first client .ovpn
new_client "$client" "$HOME"

# Start the OpenVPN service
ln -s /etc/openvpn/server/server.conf /etc/openvpn/openvpn.conf
service openvpn start

echo "OpenVPN server is set up."
echo "Client config available at: ~/$client.ovpn"
