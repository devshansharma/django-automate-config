#! /bin/bash

# defined variables, 
DOMAIN='xyz.com'
SECOND_DOMAIN=''
SYSTEMD_PATH=/etc/systemd/system/
CURRENT_PATH=$(pwd)
SYSTEM_USER=$SUDO_USER
APPLICATION=''
SECRET_KEY=$(openssl rand -base64 40)

CELERYD_NODES="w1 w2"
CELERY_BIN="${CURRENT_PATH}/.venv/bin/celery"
CELERYD_MULTI="multi"
CELERYD_OPTS="--time-limit=300 --concurrency=1"
CELERYD_LOG_FILE="/var/log/celery/%n%I.log"
CELERYD_PID_FILE="/var/run/celery/%n.pid"
CELERYD_LOG_LEVEL="INFO"


# will set up gunicorn socket to start gunicorn service
function gunicorn_socket () 
{
	echo "1. Setting up gunicorn socket."
	touch ${SYSTEMD_PATH}dj_${APPLICATION}_gunicorn.socket
	cat <<EOF > ${SYSTEMD_PATH}dj_${APPLICATION}_gunicorn.socket
[Unit]
Description=${APPLICATION} Gunicorn Socket

[Socket]
ListenStream=${CURRENT_PATH}/gunicorn.sock

[Install]
WantedBy=sockets.target
EOF
	
}


# will set up gunicorn service 
function gunicorn_service ()
{
	echo "2. Setting up gunicorn service."
	touch ${SYSTEMD_PATH}dj_${APPLICATION}_gunicorn.service
	cat <<EOF > ${SYSTEMD_PATH}dj_${APPLICATION}_gunicorn.service
[Unit]
Description=${APPLICATION} Gunicorn Daemon
Requires=dj_${APPLICATION}_gunicorn.socket
After=network.target

[Service]
User=${SYSTEM_USER}
Group=www-data
WorkingDirectory=${CURRENT_PATH}
EnvironmentFile=${CURRENT_PATH}/.env
ExecStart=${CURRENT_PATH}/.venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:${CURRENT_PATH}/gunicorn.sock ${APPLICATION}.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
	
}


# configure nginx
function nginx_configure () {
	echo "3. Setting up nginx virtual host file"
	if test -f "/etc/nginx/sites-available/${DOMAIN}"; then
		echo "File Present: Skipping Nginx Configuration."
		return 1
	fi
	touch /etc/nginx/sites-available/${DOMAIN}
	cat <<EOF > /etc/nginx/sites-available/${DOMAIN}
server {
	listen 80;
	server_name ${DOMAIN} ${SECOND_DOMAIN};

	gzip on;
	gzip_comp_level 5;
	gzip_min_length 256;
	gzip_proxied any;
	gzip_vary on;
	gzip_types application/javascript application/json application/xml text/css text/plain text/x-cross-domain-policy;

	location ~* favicon {
		root ${CURRENT_PATH}/static/favicon_io;
		expires 1d;
	}
	
	location /static/ {
		root ${CURRENT_PATH};
		expires 1d;
	}

	location /media/ {
		root ${CURRENT_PATH};
		expires 1d;
	}

	location / {
		include proxy_params;
		proxy_pass http://unix:${CURRENT_PATH}/gunicorn.sock;	
	}
}
EOF
	ln -s /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/ 2> /dev/null

}


# setting up celery system
function celery_configure ()
{
	echo "4. Setting up celery configuration"
	touch ${SYSTEMD_PATH}dj_${APPLICATION}_celery.service	
	id -u celery &> /dev/null || useradd celery -d /home/celery -b /bin/bash 2> /dev/null
	mkdir /var/log/celery 2> /dev/null
	mkdir /var/run/celery 2> /dev/null
	cat << EOF > ${SYSTEMD_PATH}dj_${APPLICATION}_celery.service
[Unit]
Description=${APPLICATION} Celery Daemon
After=network.target

[Service]
Type=forking
User=celery
Group=celery
WorkingDirectory=${CURRENT_PATH}
ExecStart=/bin/sh -c '${CELERY_BIN} multi start ${CELERYD_NODES} -A ${APPLICATION} --pidfile=${CELERYD_PID_FILE} --logfile=${CELERYD_LOG_FILE} --loglevel=${CELERYD_LOG_LEVEL} ${CELERYD_OPTS}'
ExecStop=/bin/sh -c '${CELERY_BIN} multi stopwait ${CELERYD_NODES} --pidfile=${CELERYD_PID_FILE}'
ExecReload=/bin/sh -c '${CELERY_BIN} multi restart ${CELERYD_NODES} -A ${APPLICATION} --pidfile=${CELERYD_PID_FILE} --logfile=${CELERYD_LOG_FILE} --loglevel=${CELERYD_LOG_LEVEL} ${CELERYD_OPTS}'

[Install]
WantedBy=multi-user.target
EOF
	chown -R celery:celery /var/run/celery
	chown -R celery:celery /var/log/celery
	chmod -R ug+rwx /var/run/celery
	chmod -R ug+rwx /var/log/celery
}

# create file for environment variables
function create_env_file ()
{
	echo "5. Creating environment file."
	if test -f "${CURRENT_PATH}/.env"; then
		echo "File Present: Skipping Env File."
		return 1
	fi
	cat << EOF > ${CURRENT_PATH}/.env
DJANGO_SETTINGS_MODULE=${APPLICATION}.settings.base
DEBUG=False
SECRET_KEY=${SECRET_KEY}
JWT_KEY=
DB_NAME=
DB_USER=
DB_PASSWORD=
DB_HOST=localhost
OLD_EMAIL_BACKEND='django.core.mail.backends.console.EmailBackend'
EMAIL_BACKEND='sendgrid_backend.SendgridBackend'
SENDGRID_API_KEY=''
SENDGRID_SANDBOX_MODE_IN_DEBUG=True
SENDGRID_ECHO_TO_STDOUT=True
EMAIL_HOST='smtp.sendgrid.net'
EMAIL_PORT=587
EMAIL_HOST_USER=
EMAIL_HOST_PASSWORD=
EMAIL_USE_TLS=True
ALLOWED_HOSTS=.${DOMAIN} .${SECOND_DOMAIN}
EOF
	
}


# restart services
function restart_services ()
{
	echo "7. Restarting services"
	systemctl restart nginx
	systemctl restart dj_${APPLICATION}_gunicorn.socket
	systemctl enable dj_${APPLICATION}_gunicorn.socket
	if [[ $CONFIGURE_CELERY =~ ^[Yy]$ ]];then
		echo "Restarting celery"
		systemctl restart dj_${APPLICATION}_celery.service
		systemctl enable dj_${APPLICATION}_celery.service
	fi
	systemctl daemon-reload
}


function django_settings () {
	echo "6. Creating files for Django Settings"
	local SETTINGS_PATH="${CURRENT_PATH}/${APPLICATION}/settings"
	if [ ! -d "${SETTINGS_PATH}" ];then
		mkdir "${SETTINGS_PATH}"
		touch "${SETTINGS_PATH}/__init__.py"
		cp "${CURRENT_PATH}/${APPLICATION}/settings.py" "${SETTINGS_PATH}/base.py"
		sudo chown -R ${SYSTEM_USER}:${SYSTEM_USER} ${SETTINGS_PATH}
	fi
}


: '
This function will execute first
1. set up gunicorn socket
2. set up gunicorn service
3. set up nginx configuration
4. create user for celery
5. set up celery service
'
function init () 
{
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root."
		exit 1
	fi
	
	echo "Setting up Django environment:"	
	read -p "Enter domain name: " DOMAIN || exit 1
	read -p "Enter another domain name: " SECOND_DOMAIN
	read -p "Enter application name: " APPLICATION || exit 1
	read -p "Do you want to configure Celery?" -n 1 -r CONFIGURE_CELERY
	echo

	gunicorn_socket
	gunicorn_service
	nginx_configure

	if [[ $CONFIGURE_CELERY =~ ^[Yy]$ ]];then
		echo "Making changes in celery configuration."
		celery_configure
	else 
		echo "4. Skipping Celery Configuration"
	fi
	
	create_env_file
	django_settings
	restart_services

}


init
