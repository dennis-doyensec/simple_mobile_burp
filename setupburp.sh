#!/bin/bash

emulator=~/Library/Android/sdk//emulator/emulator
instpath="/data/local/tmp/install_cert.sh"
proxyip="10.0.2.2"
proxyport="8080"

hasdevices() {
	if adb devices |grep -q 'device\s*$' ; then 
		return 0
	fi
	return 1
}

startemulator() {
	if hasdevices; then 
		echo device already running;
	else
		avd=$($emulator -snapshot-list |grep -v '^INFO' |cut -f1 |head -1)
		echo starting device $avd
		$emulator -avd $avd &
		for i in {1..200}; do
			echo sleeping until device is up!
			if hasdevices; then
				echo "device is up now!"
				break
			fi
			sleep 1
		done
	fi
}

getroot() {
	if adb shell "id -u" |grep -q "^0$"; then
		echo you are root already
	else
		echo attempting to get root
		adb root
		if adb shell "id -u" |grep -q "^0$"; then
			return -1
		else
			return 0
		fi
	fi
}

canfindburp() {
	if adb shell "if echo -en 'GET / HTTP1.0\n\n' |nc $proxyip $proxyport |grep -q 'Burp Suite'; then echo yes; fi" |grep -q "yes"; then
		return 0
	else
		return -1
	fi
}

setproxy() {
	proxy=$(adb shell settings list global |grep ^http_proxy)
	if [ "$proxy" == "http_proxy=${proxyip}:${proxyport}" ]; then
		echo "Proxy config already set: $proxy"
	else
		adb shell settings put global http_proxy 10.0.2.2:8080
		echo Proxy config set: $(adb shell settings list global |grep ^http_proxy)
	fi
}

update_phone() {
	out=$(adb shell "if [[ -e $instpath ]]; then /data/local/tmp/install_cert.sh && echo yes; fi")
	if echo $out |grep -q "yes"; then
		echo $out
		return 0
	fi
	return 1
}

if ! curl -s 127.0.0.1:${proxyport} |grep -q 'Burp Suite Professional'; then
	echo No burp on port  ${proxyport}
	exit 1
fi
startemulator

if ! canfindburp; then
	echo "== ERROR =="
	echo "[!!] can't find burp at ${proxyip}:${proxyport}"
	echo -e "\tmodify porxyip and port variables to fix"
	if [ $proxyip == "10.0.2.2" ]; then
		echo -e "\tNote: proxy ip $proxyip only works on android emulators"
	fi
	exit -1
else
	echo "Burp reachable from emulator at ${proxyip}:${proxyport} "
fi

if ! getroot; then
	echo failed to get root
	exit -1
fi

setproxy
if update_phone; then
	echo update worked I guess
	exit 0
fi

setproxy

start="/tmp/burpandroidcastuff_"
pem_file=$(mktemp /tmp/burppem-XXXXXXX)
curl -s --proxy http://127.0.0.1:8080 http://burp/cert \
	| openssl x509 -inform DER -out $pem_file


newname="$(openssl x509 -inform PEM -subject_hash_old -in $pem_file |head -1)".0
mv $pem_file /tmp/$newname
echo /tmp/$newname

locationdir=/data/local/tmp
certpath="$locationdir/$newname"

cat << EOF > install_cert.sh
if [[ -e /system/etc/security/cacerts/$newname ]]; then
	echo file already exists at /system/etc/security/cacerts/$certpath
	exit 0
fi
# Create a separate temp directory, to hold the current certificates
# Otherwise, when we add the mount we can't read the current certs anymore.
mkdir -p -m 700 /data/local/tmp/tmp-ca-copy

# Copy out the existing certificates
cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/tmp-ca-copy/

# Create the in-memory mount on top of the system certs folder
mount -t tmpfs tmpfs /system/etc/security/cacerts

# Copy the existing certs back into the tmpfs, so we keep trusting them
mv /data/local/tmp/tmp-ca-copy/* /system/etc/security/cacerts/

# Copy our new cert in, so we trust that too
cp $certpath /system/etc/security/cacerts/

# Update the perms & selinux context labels
chown root:root /system/etc/security/cacerts/*
chmod 644 /system/etc/security/cacerts/*
chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*

# Deal with the APEX overrides, which need injecting into each namespace:

# First we get the Zygote process(es), which launch each app
ZYGOTE_PID=\$(pidof zygote || true)
ZYGOTE64_PID=\$(pidof zygote64 || true)
# N.b. some devices appear to have both!

# Apps inherit the Zygote's mounts at startup, so we inject here to ensure
# all newly started apps will see these certs straight away:
for Z_PID in "\$ZYGOTE_PID" "\$ZYGOTE64_PID"; do
    if [ -n "\$Z_PID" ]; then
        nsenter --mount=/proc/\$Z_PID/ns/mnt -- \
            /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts
    fi
done

# Then we inject the mount into all already running apps, so they
# too see these CA certs immediately:

# Get the PID of every process whose parent is one of the Zygotes:
APP_PIDS=\$(
    echo "\$ZYGOTE_PID \$ZYGOTE64_PID" | \
    xargs -n1 ps -o 'PID' -P | \
    grep -v PID
)

# Inject into the mount namespace of each of those apps:
for PID in \$APP_PIDS; do
    nsenter --mount=/proc/\$PID/ns/mnt -- \
        /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts &
done
wait # Launched in parallel - wait for completion here

echo "System certificate injected"
EOF
echo adb push /tmp/$newname install_cert.sh $locationdir
adb push /tmp/$newname install_cert.sh $locationdir
adb shell "chmod +x $instpath"

adb shell "if [[ -e /data/local/tmp/install_cert.sh ]]; then /data/local/tmp/install_cert.sh; echo yes; fi"
