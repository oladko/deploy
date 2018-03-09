#!/bin/bash

	set -eo pipefail

	# allow any of these "Authentication Unique Keys and Salts." to be specified via
	# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
	uniqueEnvs=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	envs=(
		MYSQL_HOST
		MYSQL_USER
		MYSQL_PASSWORD
		MYSQL_DATABASE
		DEBUG
	)
	haveConfig=
	for e in "${envs[@]}"; do
		if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
			haveConfig=1
		fi
	done

	# only touch "wp-config.php" if we have environment-supplied configuration values
	if [ "$haveConfig" ]; then
		: "${MYSQL_HOST:=mysql}"
		: "${MYSQL_USER:=root}"
		: "${MYSQL_PASSWORD:=}"
		: "${MYSQL_DATABASE:=wordpress}"

		# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
		# https://github.com/docker-library/wordpress/issues/116
		# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4

		if [ ! -e wp-config.php ]; then
			sed -ri -e 's/\r//' wp-config-sample.php
			awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config-sample.php > wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}

define( 'WP_HOME', 'http://' . $_SERVER['HTTP_HOST'] . '/');
define( 'WP_SITEURL', 'http://' . $_SERVER['HTTP_HOST'] . '/');
EOPHP
#			chown "$user:$group" wp-config.php
		fi

		# see http://stackoverflow.com/a/2705678/433558
		sed_escape_lhs() {
			echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
		}
		sed_escape_rhs() {
			echo "$@" | sed -e 's/[\/&]/\\&/g'
		}
		php_escape() {
			local escaped="$(php -r 'var_export(('"$2"') $argv[1]);' -- "$1")"
			if [ "$2" = 'string' ] && [ "${escaped:0:1}" = "'" ]; then
				escaped="${escaped//$'\n'/"' + \"\\n\" + '"}"
			fi
			echo "$escaped"
		}
		set_config() {
			key="$1"
			value="$2"
			var_type="${3:-string}"
			start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
			end="\);"
			if [ "${key:0:1}" = '$' ]; then
				start="^(\s*)$(sed_escape_lhs "$key")\s*="
				end=";"
			fi
			sed -ri -e "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" wp-config.php
		}

		set_config 'DB_HOST' "$MYSQL_HOST"
		set_config 'DB_USER' "$MYSQL_USER"
		set_config 'DB_PASSWORD' "$MYSQL_PASSWORD"
		set_config 'DB_NAME' "$MYSQL_DATABASE"

		for unique in "${uniqueEnvs[@]}"; do
			uniqVar="WORDPRESS_$unique"
			if [ -n "${!uniqVar}" ]; then
				set_config "$unique" "${!uniqVar}"
			else
				# if not specified, let's generate a random value
				currentVal="$(sed -rn -e "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" wp-config.php)"
				if [ "$currentVal" = 'put your unique phrase here' ]; then
					set_config "$unique" "$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)"
				fi
			fi
		done

		if [ "$DEBUG" ]; then
			set_config 'WP_DEBUG' 1 boolean
		fi
	fi
