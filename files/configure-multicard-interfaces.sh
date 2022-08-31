#!/usr/bin/env bash

get_metadata() {
		TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
		attempts=60
		false
		while [ "${?}" -gt 0 ]; do
	if [ "${attempts}" -eq 0 ]; then
			echo "Failed to get metdata"
			exit 1
	fi
	meta=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/${1})
	if [ "${?}" -gt 0 ]; then
			let attempts--
			sleep 0.5
			false
	fi
		done
		echo "$meta"
}

INSTANCE_TYPE=$(get_metadata "instance-type")

if [ "$INSTANCE_TYPE" != "p4d.24xlarge" && "$INSTANCE_TYPE" != "p4de.24xlarge" ]; then
		exit 0
fi

echo "instance type is $INSTANCE_TYPE"

PRIMARY_MAC=$(get_metadata 'mac')
# PRIMARY_MAC=$(curl -v http://169.254.169.254/latest/meta-data/mac -H "X-aws-ec2-metadata-token: $TOKEN")
PRIMARY_IF=$(ip -o link show | grep -F "link/ether $PRIMARY_MAC" | awk -F'[ :]+' '{print $2}')
ALL_MACS=$(get_metadata 'network/interfaces/macs')
# ALL_MACS=$(curl -v http://169.254.169.254/latest/meta-data/network/interfaces/macs -H "X-aws-ec2-metadata-token: $TOKEN")

MAC_ARRAY=($ALL_MACS)
TABLE_ID=1001
PREF_ID=32765
for MAC in "${MAC_ARRAY[@]}"; do
		TRIMMED_MAC=$(echo $MAC | sed 's:/*$::')
		IF_NAME=$(ip -o link show | grep -F "link/ether $TRIMMED_MAC" | awk -F'[ :]+' '{print $2}')

		echo "handling interface $IF_NAME"

		config_file="/etc/sysconfig/network-scripts/ifcfg-${IF_NAME}"
		route_file="/etc/sysconfig/network-scripts/route-${IF_NAME}"
		if [ "$IF_NAME" = "$PRIMARY_IF" ]; then
	echo "skipping primary interface"
		else
	ifdown $IF_NAME
	rm -f ${config_file}
	rm -f ${route_file}
	IF_IP=$(get_metadata "network/interfaces/macs/$TRIMMED_MAC/local-ipv4s" | head -1)
	echo "got interface ip $IF_IP"
	CIDR=$(get_metadata "network/interfaces/macs/$TRIMMED_MAC/subnet-ipv4-cidr-block")

	echo "got cidr $CIDR"
	echo "using table $TABLE_ID"
	echo "using rule preference $PREF_ID"

	network=$(echo ${CIDR} | cut -d/ -f1)
	router=$(($(echo ${network} | cut -d. -f4) + 1))
	GATEWAY_IP="$(echo ${network} | cut -d. -f1-3).${router}"
	echo $GATEWAY_IP
	cat <<-EOF >${config_file}
						DEVICE=${IF_NAME}
						BOOTPROTO=dhcp
						ONBOOT=yes
						TYPE=Ethernet
						USERCTL=yes
						PEERDNS=no
						IPV6INIT=yes
						DHCPV6C=yes
						DHCPV6C_OPTIONS=-nw
						PERSISTENT_DHCLIENT=yes
						HWADDR=${TRIMMED_MAC}
						DEFROUTE=no
						EC2SYNC=yes
						MAINROUTETABLE=no
				EOF

	ip link set dev $IF_NAME mtu 9001
	ifup $IF_NAME

	ip route add default via $GATEWAY_IP dev $IF_NAME table $TABLE_ID
	ip route add $CIDR dev $IF_NAME proto kernel scope link src $IF_IP table $TABLE_ID
	ip rule add from $IF_IP lookup $TABLE_ID pref $PREF_ID

	((TABLE_ID = TABLE_ID + 1))
	((PREF_ID = PREF_ID - 1))
		fi
done
