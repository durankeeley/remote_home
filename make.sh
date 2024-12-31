#!/bin/sh

# Install OpenVPN
./alpine-install-openvpn.sh

generate_guid() {
  dd if=/dev/urandom bs=16 count=1 2>/dev/null \
    | hexdump -v -e '1/1 "%02x"' \
    | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
}

cp env.example .env --update=none

# Generate a new GUID for the admin key apisix
apisix_admin_apikey="$(generate_guid)"
if grep -q "edd1c9f034335f136f87ad84b625c8f1" "./apisix/apisix/config.yaml"; then
  sed -i "s/edd1c9f034335f136f87ad84b625c8f1/${apisix_admin_apikey}/g" "./apisix/apisix/config.yaml"
  echo "APISIX_ADMIN_APIKEY=\"${apisix_admin_apikey}\"" >> .secrets
fi

# Generate a new password for the guacamole administrator
guacamole_administrator_password="$(generate_guid)"
if grep -q "administratorpassword" "./guacamole/mariadb/init-guacdb.sql"; then
  sed -i "s/administratorpassword/${guacamole_administrator_password}/g" "./guacamole/mariadb/init-guacdb.sql"
  echo "GUACAMOLE_PASSWORD=\"${guacamole_administrator_password}\"" >> .secrets
fi

# Generate a new password for the guacamole database root user
guacamole_database_root_password="$(generate_guid)"
if grep -q 'guacamole_db_root_password=""' ".env"; then
  sed -i "s/guacamole_db_root_password=\"\"/guacamole_db_root_password=\"${guacamole_database_root_password}\"/g" ".env"
fi

# Generate a new password for the guacamole user
guacamole_database_password="$(generate_guid)"
if grep -q 'guacamole_db_password=""' ".env"; then
  sed -i "s/guacamole_db_password=\"\"/guacamole_db_password=\"${guacamole_database_password}\"/g" ".env"
fi

echo "Starting Containers"
apk add docker docker-compose 
docker-compose up -d
