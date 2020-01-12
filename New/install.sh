#!/bin/bash

IMAGE=nftcontroller
PREFIX=${IMAGE}_
INSTALL_NAME=./install.sh
BRIDGE=${IMAGE}-bridge
DOCKER_VMAJOR=1
DOCKER_VMINOR=9
DOCKER_VMICRO=1
APP_PATH=/opt/${IMAGE}

DEFAULT_CONFIG="LIB_PATH=$APP_PATH/lib
FIRMWARES_PATH=\$LIB_PATH/firmwares
TROUBLESHOOTS_PATH=\$LIB_PATH/troubleshoots
FLOORMAPS_PATH=\$LIB_PATH/floormaps
CERTS_PATH=\$LIB_PATH/certs
LETSENCRYPT_PATH=\$LIB_PATH/letsencrypt
HTTP_PORT=80
HTTPS_PORT=443
DEBUG=false"

eval "$DEFAULT_CONFIG"

if [ -f $APP_PATH/etc/${IMAGE}.config ]; then
	source $APP_PATH/etc/${IMAGE}.config
fi

# do not change these paths, they are used inside containers
FIRMWARES_VOL=/home/andromeda/firmwares
TROUBLESHOOTS_VOL=/home/andromeda/troubleshoots
FLOORMAPS_VOL=/home/andromeda/floormaps
CERTS_VOL=/home/andromeda/certs
VOLUME=/home/andromeda/shared

CONTAINERS="influx arango vernemq rabbitmq celery_main celery_periodic celery_beat tornado collector nginx"
OPTIONS_influx="-e CONTAINER=influx"
OPTIONS_DEBUG_influx="-p 8083:8083 -p 8086:8086"
OPTIONS_arango="-e CONTAINER=arango"
OPTIONS_DEBUG_arango="-p 8529:8529"
OPTIONS_mosquitto="-e CONTAINER=broker -p 1883:1883 -p 8883:8883 -v $CERTS_PATH:$CERTS_VOL:rw"
OPTIONS_DEBUG_mosquitto=
OPTIONS_collector="-e CONTAINER=collector -v $CERTS_PATH:$CERTS_VOL:ro -v $FIRMWARES_PATH:$FIRMWARES_VOL:ro \
    -v $TROUBLESHOOTS_PATH:$TROUBLESHOOTS_VOL:rw"
OPTIONS_DEBUG_collector=
OPTIONS_rabbitmq="-e CONTAINER=rabbitmq"
OPTIONS_DEBUG_rabbitmq="-p 5672:5672"
OPTIONS_celery_main="-e CONTAINER=celery -e CELERY_TYPE=worker -e CELERY_QUEUES=celery \
    -v $TROUBLESHOOTS_PATH:$TROUBLESHOOTS_VOL:rw"
OPTIONS_DEBUG_celery_main=
OPTIONS_celery_periodic="-e CONTAINER=celery -e CELERY_TYPE=worker -e CELERY_QUEUES=periodic \
    -v $TROUBLESHOOTS_PATH:$TROUBLESHOOTS_VOL:rw"
OPTIONS_DEBUG_celery_periodic=
OPTIONS_celery_beat="-e CONTAINER=celery -e CELERY_TYPE=beat"
OPTIONS_DEBUG_celery_beat=
OPTIONS_tornado="-e CONTAINER=tornado -v $LETSENCRYPT_PATH:/etc/letsencrypt:rw \
	-v $CERTS_PATH:$CERTS_VOL:ro -v $FIRMWARES_PATH:$FIRMWARES_VOL:rw\
        -v $FLOORMAPS_PATH:$FLOORMAPS_VOL:rw\
	-v $TROUBLESHOOTS_PATH:$TROUBLESHOOTS_VOL:rw"
OPTIONS_DEBUG_tornado=" -p 6363:8888"
OPTIONS_geodata="-e CONTAINER=geodata"
OPTIONS_nginx="-e CONTAINER=nginx -v $CERTS_PATH:$CERTS_VOL:ro -v $LETSENCRYPT_PATH:/etc/letsencrypt:rw" 
OPTIONS_DEBUG_nginx=
OPTIONS_vernemq="-e CONTAINER=vernemq --net-alias nftcontroller_mosquitto -p 1883:1883 -p 8883:8883 -v $CERTS_PATH:$CERTS_VOL:rw"
OPTIONS_DEBUG_vernemq="-p 1884:1884"

stop_container() {
	docker ps | grep ${PREFIX}$1 >/dev/null && \
		echo -n "Stopped: " && docker stop ${PREFIX}$1
	docker ps -a | grep ${PREFIX}$1 >/dev/null && \
		echo -n "Removed: " && docker rm ${PREFIX}$1
}

start_container() {
	docker ps | grep ${PREFIX}$1 >/dev/null && \
		echo "$1 is already running" && return
	OPTIONS_PORTS=
	if [[ $1 == 'mosquitto' ]]; then
		MOSQ_PORTS="1883 8883"
		for port in $MOSQ_PORTS; do
			nc -vz 0.0.0.0 $port &>/dev/null
			if [[ $? == 0 ]]; then
				echo "Can not start mosquitto service: TCP port $port is in use!"
				echo "This service requires TCP ports 1883 and 8883"
				exit 1
			fi
		done
	elif [[ $1 == 'nginx' ]]; then
		if [ ! -z $HTTP_PORT ] && [ -z $HTTPS_PORT ]; then
			# only http
			OPTIONS_PORTS="-p ${HTTP_PORT}:6080"
			TORN_PORTS="$HTTP_PORT"
		elif [ -z $HTTP_PORT ] && [ ! -z $HTTPS_PORT ]; then
			# only https
			OPTIONS_PORTS="-p ${HTTPS_PORT}:6443"
			TORN_PORTS="$HTTPS_PORT"
		elif [ ! -z $HTTP_PORT ] && [ ! -z $HTTPS_PORT ]; then
			# http and https
			OPTIONS_PORTS="-p ${HTTP_PORT}:6080 -p ${HTTPS_PORT}:6443"
			TORN_PORTS="$HTTP_PORT $HTTPS_PORT"
		else
			OPTIONS_PORTS=
			TORN_PORTS=
		fi
		for port in $TORN_PORTS; do
			nc -vz 0.0.0.0 $port &>/dev/null
			if [[ $? == 0 ]]; then
				echo "Can not start web service: TCP port $port is in use!"
				echo -n "Currently configured ports are: "
				echo "${HTTP_PORT} for HTTP and ${HTTPS_PORT} for HTTPS"
				echo -n "Port configuration can be changed in "
				echo "$APP_PATH/etc/${IMAGE}.config"
				exit 1
			fi
		done
	fi
	echo "Starting $1"
	docker run -d -v /etc/localtime:/etc/localtime:ro \
		-v $LIB_PATH/$1:$VOLUME:rw "${@:2}" ${OPTIONS_PORTS} \
		--restart=always --net=${BRIDGE} \
		--name ${PREFIX}$1 ${IMAGE} >/dev/null
}

load_image() {
	if [ ! -f $1 ]; then
		echo "Image $1 not found"
		exit 1
	fi
	VERSION=$(tar -xOf $1 repositories | \
		sed -n "s/.*\"${IMAGE}\":{\"\([A-Za-z0-9._-]*\)\".*/\1/p")
	if [[ -z $VERSION ]]; then echo "Invalid image"; exit 1; fi
	OLD=$(docker images -q ${IMAGE}:latest 2> /dev/null)
	if [[ "$OLD" != "" ]]; then
		echo "Removing old image"
		docker rmi -f $OLD
	fi
	echo "Loading new image $VERSION"
	docker load -i $1
	docker tag ${IMAGE}:${VERSION} ${IMAGE}:latest
}

container_version() {
	HASH=$(docker images -q ${IMAGE}:latest 2> /dev/null)
	if [[ "$HASH" != "" ]]; then
		docker images ${IMAGE} | grep $HASH | grep -v latest | awk '{print $2}'
	else
		echo "${IMAGE} not installed"
	fi
}

copy_script() {
	mkdir -p $APP_PATH
	mkdir -p $APP_PATH/bin/
	mkdir -p $APP_PATH/etc/
	mkdir -p $APP_PATH/lib/
	cp $1 $APP_PATH/bin/${IMAGE}
	if [ ! -f $APP_PATH/etc/${IMAGE}.config ]; then
		cat > $APP_PATH/etc/${IMAGE}.config << EOL
${DEFAULT_CONFIG}
EOL
	ln -s -f $APP_PATH/bin/${IMAGE} /usr/bin/${IMAGE}
	fi
}

create_bridge() {
	docker network inspect $BRIDGE &> /dev/null || \
		docker network create -d bridge $BRIDGE >/dev/null
	if [ $? != 0 ]; then
		echo "Failed to create Docker bridge"
		exit 1
	fi
}

docker_status() {
	which docker > /dev/null
	if [ $? != 0 ]; then
		echo "Docker not installed. Please install latest stable Docker server"
		install_docker
		exit 1
	fi
	docker info &> /dev/null
	if [ $? != 0 ]; then
		echo "Could not connect to Docker daemon. Make sure Docker service is running"
		exit 1
	fi
	return 0
}

install_docker() {
	echo -n "Controller is a containerized application and requires Docker Engine "
	echo "(https://www.docker.com/)"
	echo "Latest Docker version can be installed by executing the following command:"
	echo "curl -fsSL https://get.docker.com/ | sh"
}

print_bad_docker() {
	echo -n "Unsupported Docker version ($1) found. "
	echo -n "Minimum supported version: "
	echo ${DOCKER_VMAJOR}.${DOCKER_VMINOR}.${DOCKER_VMICRO}
}

docker_version() {
	version=`docker version --format '{{.Server.Version}}' 2> /dev/null`
	if [ $? != 0 ]; then
		print_bad_docker " "
		install_docker
		exit 1
	fi
	IFS=. read major minor micro <<< "${version%-*}"
	if [ $major -gt $DOCKER_VMAJOR ]; then
		return 0
	elif [ $major -eq $DOCKER_VMAJOR ]; then
		if [ $minor -gt $DOCKER_VMINOR ]; then
			return 0
		elif [ $minor -eq $DOCKER_VMINOR ]; then
			if [ $micro -ge $DOCKER_VMICRO ]; then
				return 0
			else
				print_bad_docker $version
				install_docker
				exit 1
			fi
		else
			print_bad_docker $version
			install_docker
			exit 1
		fi
	else
		print_bad_docker $version
		install_docker
		exit 1
	fi
}

# migrate_configs will remove influx config and products.json file and create 
# copies of current mosquitto and collector configs, so that they would be 
# overwritten with newest config versions.
migrate_configs() {
	# remove influx cfg if exists
	INFLUX_CFG="$LIB_PATH/influx/influxdb.conf"
	if [ -f $INFLUX_CFG ] ; then
		rm $INFLUX_CFG
	fi		

	# remove products.json from tornado lib path if it exists
	PF="$LIB_PATH/tornado/products.json"
	if [ -f $PF ] ; then
		rm $PF
	fi

	# backup and update mosquitto configuration
	MC="$LIB_PATH/mosquitto/mosquitto.conf"
	if [ -f $MC ]; then
		mv $MC $MC.backup
	fi

	# backup and update collector configuration
	CC="$LIB_PATH/collector/collector.toml"
	if [ -f $CC ]; then
		mv $CC $CC.backup
	fi
}

setup_certs() {
	mkdir -p $CERTS_PATH || exit 1
	if [ -f $CERTS_PATH/domain ]; then
		return 0
	fi
	echo "Please select HTTPS security mode"
	echo "1) HTTP only, No SSL/TLS certificates"
	echo "   - Insecure, unencrypted connection. For private networks only"
	echo "2) HTTPS with self-signed SSL/TLS certificates"
	echo "   - Insecure, encrypted connection. Web browsers will display sertificate error"
	echo "3) HTTPS with free certificates from Letsencrypt service"
	echo "   - Secure, requires a valid domain and open default TCP ports (80,443)"
	echo "   - by using this option you agree to Letsencrypt terms and conditions (https://letsencrypst.org/repository/)"
	echo -n "HTTPS mode [default 2]: "
	read secure
	if [[ $secure == '1' ]]; then
		echo -n "Please enter TCP port number for web interface [default 7080]: "
		read port
		if [[ $port == "" ]]; then
			HTTP_PORT=7080
		elif case $port in ''|*[!0-9]*) true ;; *) false ;; esac; then
			echo "Invalid port: must be a number from 1 to 65535"
			exit 1
		elif [ $port -le 0 ] || [ $port -ge 65536 ]; then
			echo "Invalid port: must be a number from 1 to 65535"
			exit 1
		else
			HTTP_PORT=$port
		fi
		HTTPS_PORT=
	elif [[ $secure == '2' || $secure == "" ]]; then
		echo -n "Please enter TCP port number for web interface [default 7443]: "
		read port
		if [[ $port == "" ]]; then
			HTTPS_PORT=7443
		elif case $port in ''|*[!0-9]*) true ;; *) false ;; esac; then
			echo "Invalid port: must be a number from 1 to 65535"
			exit 1
		elif [ $port -le 0 ] || [ $port -ge 65536 ]; then
			echo "Invalid port: must be a number from 1 to 65535"
			exit 1
		else
			HTTPS_PORT=$port
		fi
		HTTP_PORT=
	elif [[ $secure == '3' ]]; then
		HTTP_PORT=80
		HTTPS_PORT=443
	else
		echo "Error: invalid option"
		exit 1
	fi
	if [[ $secure == '3' ]]; then
		echo "Please enter a valid public domain address of the server."
		echo -e -n "\033[0;31mNOTE: only this domain can be used "
		echo -e "by devices to connect to the server\033[0m"
		echo -n "Domain: "
		read answer
		if [[ $answer =~ \
			^(([a-zA-Z](-?[a-zA-Z0-9])*)\.)*[a-zA-Z](-?[a-zA-Z0-9])+\.[a-zA-Z]{2,}$ \
		   ]]; then
			echo $answer > $CERTS_PATH/domain
			echo "domains = $answer" > $CERTS_PATH/letsencrypt.ini
		else
			echo "Invalid domain entered: Letsencrypt service requires a valid domain to be used"
			exit 1
		fi
	else
		echo "Please enter the domain or IP address of the server."
		echo -e -n "\033[0;31mNOTE: only this domain can be used "
		echo -e "by devices to connect to the server\033[0m"
		echo -n "Domain/IP: "
		read answer
		echo $answer > $CERTS_PATH/domain
		if [[ $secure == '2' || $secure == "" ]]; then
			mkdir -p $CERTS_PATH/http
			cd $CERTS_PATH/http
			ln -s ../server.crt server.crt
			ln -s ../server.key server.key
			cd - > /dev/null
		fi
	fi
	if [ -f $APP_PATH/etc/${IMAGE}.config ]; then
		sed -i "s/HTTP_PORT=.*$/HTTP_PORT=${HTTP_PORT}/" $APP_PATH/etc/${IMAGE}.config
		sed -i "s/HTTPS_PORT=.*$/HTTPS_PORT=${HTTPS_PORT}/" $APP_PATH/etc/${IMAGE}.config
	fi
	return 0
}

select_containers() {
	if [ -z $1 ]; then
		selected=$CONTAINERS
	else
		selected="${@:1}"
		for sel in $selected; do
			if case $CONTAINERS in *"${sel}"*) false;; *) true;; esac; then
				echo "Invalid container: $sel"
				exit 1
			fi
		done
	fi
}

reverse_containers() {
	revlist=
	if [[ $selected == $CONTAINERS ]]; then
		for i in $selected; do
			revlist="$i $revlist"
		done
	else
		revlist=$selected
	fi
}

export_lib() {
	echo "Exporting library to $1"
	cd ${LIB_PATH}
	tar -czf $1 *
}

import_lib() {
	echo -e "\033[0;31mWARNING: all files will be overwritten!\033[0m"
	echo "Do you want to continue? [y/N]"
	read answer
	if [[ $answer == "y" ]]; then
		echo "Importing library from $1"
		rm -rf ${LIB_PATH}
		mkdir -p ${LIB_PATH}
		cd ${LIB_PATH}
		tar -xzf $1
	fi
}

uninstall() {
	if [ ! -f $APP_PATH/bin/${IMAGE} ]; then
		echo "${IMAGE} is not installed"
		exit 1
	fi
	echo "Do you want to remove the Docker image? [Y/n]"
	read answer
	if [[ $answer != "n" && $answer != "N" && $answer != "no" ]]; then
		OLD=$(docker images -q ${IMAGE}:latest 2> /dev/null)
		if [[ "$OLD" != "" ]]; then
			echo "Uninstalling Docker image"
			docker rmi -f $OLD
		else
			echo "No Docker image found"
		fi
	fi
	echo "Do you want to remove all user data?"
	echo -e "\033[0;31mWARNING: all databases will be lost!\033[0m"
	echo "Do you want to continue? [y/N]"
	read answer
	if [[ $answer == "y" ]]; then
		echo "Uninstalling system and library files..."
		rm -rf $APP_PATH
	else
		echo "Uninstalling only system files..."
		rm -rf $APP_PATH/etc
		rm -rf $APP_PATH/bin
	fi
	rm -f /usr/bin/${IMAGE}
	echo "${IMAGE} uninstalled successfuly"
}

do_restore() {
	stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
		select_containers $CONTAINERS
		reverse_containers
		for cont in $revlist; do
			if [[ $cont != 'arango'  ]]; then
				stop_container $cont
				fi
			done
		mkdir -p $LIB_PATH/tmp/
		tar -xzf db_backup_$time_stamp.tar.gz -C $LIB_PATH/tmp/
		backup_time_stamp=$(date +%Y_%m_%d_%H_%M_%S)
		mkdir -p $LIB_PATH/arango/backups/$backup_time_stamp
		mkdir -p $LIB_PATH/influx/backups/$backup_time_stamp
		mv $LIB_PATH/tmp/arango/* $LIB_PATH/arango/backups/$backup_time_stamp
		mv $LIB_PATH/tmp/influx/* $LIB_PATH/influx/backups/$backup_time_stamp
		rm -rf $LIB_PATH/tmp/

		docker exec -i $PREFIX"arango" /bin/bash /home/andromeda/tools/restore_arango.sh $backup_time_stamp
		if [[ $? -eq 0 ]]; then
			echo 'arango restore succeded'
		else

			echo 'Retrying...'
			# rm created dirs before error occured
			rm -r $LIB_PATH/arango/backups/$backup_time_stamp
			rm -r $LIB_PATH/influx/backups/$backup_time_stamp
			sleep 5
			do_restore
			exit 0
		fi

		stop_container "arango"
		echo "Restoring influx"
		params=OPTIONS_influx
		LOG='-e LOG_LEVEL=info'
		RESF="-e RESFOLDER=$backup_time_stamp"
		# influx gets backup on boot, so it doesn't need any shell script to
		# perform backup actions, backup is passed as $RESF
		start_container "influx" ${LOG} ${RESF} ${!params} || exit 1
		stop_container "influx"
		rm -rf $LIB_PATH/arango/backups/$backup_time_stamp
		rm -rf $LIB_PATH/influx/backups/$backup_time_stamp
                # this message appears when upgrading from lower than v12
                echo -n "Upgrade complete. If no error messages present system can be started by using: "
                echo "'sudo ${IMAGE} start' command"
                echo -n "if any error message is present upgrade again using: "
                echo "'sudo ${INSTALL_NAME} upgrade' command"
	else
		start_container "arango" $OPTIONS_arango
		do_restore
		exit 1
	fi
}

do_backup() {
	stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
		stat=`docker ps -a --filter="name=${PREFIX}influx" --format '{{.Status}}'`
		if case $stat in *"Up"*) true;; *) false;; esac; then
			orgs=`docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/list_orgs.sh`
			time_stamp=$(date +%Y_%m_%d_%H_%M_%S)
			echo "Creating backup at $time_stamp"
			echo ""
			# run BACKUP_ARANGO command and exit in case of error
			BACKUP_ARANGO=$(docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/backup_arango.sh $time_stamp "$orgs")
			if [[ $BACKUP_ARANGO ]]; then
				echo 'arango backup succeded'
			else
				echo 'error while creating arango backup'
				exit 1
			fi 
			# run BACKUP_INFLUX command and exit in case of error
			BACKUP_INFLUX=$(docker exec -i $PREFIX'influx' /bin/bash /home/andromeda/tools/backup_influx.sh $time_stamp "$orgs")
			if [[ $BACKUP_INFLUX ]]; then
				echo 'influx backup succeded'
			else
				echo 'error while creating influx backup'
				exit 1
			fi 

			mkdir -p $LIB_PATH/backup/
			mv -v $LIB_PATH/arango/backups/$time_stamp $LIB_PATH/backup/arango/
			mv $LIB_PATH/influx/backups/$time_stamp $LIB_PATH/backup/influx/
			container_version > $LIB_PATH/backup/log
			echo $time_stamp >> $LIB_PATH/backup/log
			tar -czf db_backup_$time_stamp.tar.gz -C $LIB_PATH/backup/ influx arango log
			rm -rf $LIB_PATH/backup/
		else
			echo "influx container not up"
			exit 1
		fi
	else
		echo "arango container not up"
		exit 1
	fi
}

do_install() {
	if [ -z $2 ]; then
		IMG=$(readlink -f ${IMAGE}_dockerimage.tar)
	else
		IMG=$(readlink -f $2)
	fi
	if [ -z $IMG ]; then
		echo "Image not found!"
		print_usage
		exit 1
	fi
	# stop all containers
	selected=$CONTAINERS
	reverse_containers
	for cont in $revlist; do
		stop_container $cont
	done

	copy_script $0
	setup_certs
	load_image $IMG
	create_bridge
}

print_usage() {
	echo "Usage: nftcontroller COMMAND [args]"
	echo ""
	echo "Available COMMANDS:"
	echo "    start [container1..N]       Start selected containers (or all if not specified)"
	echo "    stop [container1..N]        Stop selected containers (or all if not specified)"
	echo "    restart [container1..N]     Restart selected containers (or all if not specified)"
	echo "    install [image_path]        Install or update nftcontroller using a Docker image"
	echo "                                  (default is nftcontroller_dockerimage.tar if not specified)"
	echo "    status                      Show status of all containers"
	echo "    info                        Show information about containers"
	echo "    attach container            Connect to selected containers shell"
	echo "    backup                      Backup nftcontrollers databases"
	echo "    restore filename            Restore nftcontrollers databases"
	echo "    reset-crt                   Change server domain and reset MQTT certificates"
	echo "    export file                 Export full nftcontroller library to file"
	echo "    import file                 Import nftcontroller library from file (overwrites old files)"
	echo "    version                     Show installed system version"
	echo "    uninstall                   Uninstall the system"
	echo "    reset-superadmin-pwd        Resets superadmin password to default password"
	echo "    export-users [org,file]     Exports users data to CSV file."
        echo "    upgrade                     Upgrades nftcontroller to new version"
}

do_update_configs() {

	# we changed our main MQTT broker from mosquitto to vernemq and changed
	# intercommunication port from 1883 to 1884
	CONFIGS=(
		$APP_PATH/lib/tornado/config.py
		$APP_PATH/lib/celery_main/celeryconfig.py
		$APP_PATH/lib/celery_beat/celeryconfig.py
		$APP_PATH/lib/celery_periodic/celeryconfig.py
	)

	for FILEPATH in ${CONFIGS[*]}; do
		# in case if this is fresh install and config files does not exists yet.
		if [ ! -f $FILEPATH ]; then
			continue
		fi
		# replace nftcontroller_mosquitto to nftcontroller_vernemq
		if grep -q "nftcontroller_mosquitto" $FILEPATH; then
			echo "Updating broker name in $FILEPATH"
			sed -i 's/nftcontroller_mosquitto/nftcontroller_vernemq/g' $FILEPATH
		fi
		# replace 1883 port to 1884
		if grep -q 1883 $FILEPATH; then
			echo "Updating broker port in $FILEPATH"
			sed -i 's/1883/1884/g' $FILEPATH
		fi
	done

}

# stop deprecated containers
do_stop_deprecated() {
	stop_container geodata
	stop_container mosquitto
}

docker_status

if [[ $1 == 'start' || $1 == 'restart' ]]; then
	docker_version
	create_bridge
	do_update_configs
	setup_certs
	select_containers ${@:2}
	if [[ $1 == 'restart' ]]; then
		reverse_containers
		for cont in $revlist; do
			stop_container $cont
		done
	fi
	for cont in $selected; do
		params=OPTIONS_$cont
		paramsd=OPTIONS_DEBUG_$cont
		if $DEBUG; then
			LOG='-e LOG_LEVEL=debug'
			echo -e -n "\033[0;31mWARNING: starting $cont service in debug mode, "
			echo -e "it may be accessed from outside of this system!\033[0m"
			start_container $cont ${LOG} ${!params} ${!paramsd} || exit 1
		else
			LOG='-e LOG_LEVEL=info'
			start_container $cont ${LOG} ${!params} || exit 1
		fi
	done
elif [[ $1 == 'stop' ]]; then
	do_stop_deprecated

	# stop containers in reverse order if specific containers not selected
	select_containers ${@:2}
	reverse_containers
	for cont in $revlist; do
		stop_container $cont
	done
elif [[ $1 == 'restore'  ]]; then
	stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
	    select_containers $CONTAINERS
	    reverse_containers
        for cont in $revlist; do
            if [[ $cont != 'arango'  ]]; then
                stop_container $cont
                fi
            done
        mkdir -p $LIB_PATH/tmp/
        tar -xzf $2 -C $LIB_PATH/tmp/
        time_stamp=$(date +%Y_%m_%d_%H_%M_%S)
        mkdir -p $LIB_PATH/arango/backups/$time_stamp
        mkdir -p $LIB_PATH/influx/backups/$time_stamp
        mv $LIB_PATH/tmp/arango/* $LIB_PATH/arango/backups/$time_stamp
        mv $LIB_PATH/tmp/influx/* $LIB_PATH/influx/backups/$time_stamp
        rm -rf $LIB_PATH/tmp/
        docker exec -i $PREFIX"arango" /bin/bash /home/andromeda/tools/restore_arango.sh $time_stamp
        stop_container "arango"
        echo "Restoring influx"
        params=OPTIONS_influx
        LOG='-e LOG_LEVEL=info'
        RESF="-e RESFOLDER=$time_stamp"
        start_container "influx" ${LOG} ${RESF} ${!params} || exit 1
        stop_container "influx"
        rm -rf $LIB_PATH/arango/backups/$time_stamp
        rm -rf $LIB_PATH/influx/backups/$time_stamp

        for cont in $CONTAINERS; do
            params=OPTIONS_$cont
            paramsd=OPTIONS_DEBUG_$cont
            if $DEBUG; then
                LOG='-e LOG_LEVEL=debug'
                echo -e -n "\033[0;31mWARNING: starting $cont service in debug mode, "
                echo -e "it may be accessed from outside of this system!\033[0m"
                start_container $cont ${LOG} ${!params} ${!paramsd} || exit 1
            else
                LOG='-e LOG_LEVEL=info'
                start_container $cont ${LOG} ${!params} || exit 1
            fi
        done
    else
        echo "arango container not up"
    fi

elif [[ $1 == 'reset-superadmin-pwd'   ]]; then 
	stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
		echo "Reseting superadmin password ..."
		docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/reset_superuser.sh
	
	else
        echo "arango container not up"
	fi

elif [[ $1 == 'export-users'   ]]; then 
	stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then

		ORG_ID="$2"
		FILE_NAME="$3"

		if [[ $ORG_ID == "" ]]; then
			echo "Missing 1st argument :  <ORG_ID>"
			echo ""
			echo "./nftcontroller export-users <organization_id> <filename>"
			echo ""
			echo ""
			print_usage
		elif [[ $FILE_NAME == "" ]]; then
			echo "If filename not given, default output file will be: 'udata.csv' "
			echo ""
			echo "Collecting users data to udata.csv"
			echo ""
			echo ""
			docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/get_users_data.sh $2 > udata.csv
			echo ""
			echo ""
			echo "Data collected successfully"
		else
			echo "Collecting users data to $3"
			echo ""
			echo ""
			docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/get_users_data.sh $2 > $3
			echo ""
			echo ""
			echo "Data collected successfully"
		fi


		
	
	else
        echo "arango container not up"
	fi


elif [[ $1 == 'backup'  ]]; then
    stat=`docker ps -a --filter="name=${PREFIX}arango" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
	    stat=`docker ps -a --filter="name=${PREFIX}influx" --format '{{.Status}}'`
	    if case $stat in *"Up"*) true;; *) false;; esac; then
	        orgs=`docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/list_orgs.sh`
	        time_stamp=$(date +%Y_%m_%d_%H_%M_%S)
	        echo "Creating backup at $time_stamp"
	        echo ""
	        docker exec -i $PREFIX'arango' /bin/bash /home/andromeda/tools/backup_arango.sh $time_stamp "$orgs"
	        docker exec -i $PREFIX'influx' /bin/bash /home/andromeda/tools/backup_influx.sh $time_stamp "$orgs"
            mkdir -p $LIB_PATH/backup/
            mv -v $LIB_PATH/arango/backups/$time_stamp $LIB_PATH/backup/arango/
            mv $LIB_PATH/influx/backups/$time_stamp $LIB_PATH/backup/influx/
            container_version > $LIB_PATH/backup/log
            echo $time_stamp >> $LIB_PATH/backup/log
            tar -czf db_backup_$time_stamp.tar.gz -C $LIB_PATH/backup/ influx arango log
            rm -rf $LIB_PATH/backup/
        else
            echo "influx container not up"
        fi
    else
        echo "arango container not up"
    fi
elif [[ $1 == 'attach'  ]]; then
	stat=`docker ps -a --filter="name=${PREFIX}${2}" --format '{{.Status}}'`
	if case $stat in *"Up"*) true;; *) false;; esac; then
		docker exec -ti $PREFIX$2 /bin/bash
	else
		echo "$2 container not up"
	fi
elif [[ $1 == 'reset-crt' ]]; then
	for cont in $CONTAINERS; do
		stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
		case $stat in
			*"Up"*)
				echo "Please stop the system before using reset-crt command"
				exit 1
				;;
		esac
	done
	echo -n "WARNING: all current certificates (including Letsencrypt) will be deleted. "
	echo "Continue? [y/N]"
	read answer
	if [[ $answer == 'y' ]]; then
		rm -rf $CERTS_PATH
		rm -rf $LETSENCRYPT_PATH
		setup_certs
	fi
elif [[ $1 == 'install' ]]; then
	if [[ -d $APP_PATH ]]; then
		# if app path exists, upgrade must be used to upgrade system
		echo "${IMAGE} is already installed. Please use \"sudo ${INSTALL_NAME} upgrade\""
		exit 0
	fi

	if [ -z $2 ]; then
		IMG=$(readlink -f ${IMAGE}_dockerimage.tar)
	else
		IMG=$(readlink -f $2)
	fi
	if [ -z $IMG ]; then
		echo "Image not found!"
		print_usage
		exit 1
	fi
	# stop all containers
	selected=$CONTAINERS
	reverse_containers
	for cont in $revlist; do
		stop_container $cont
	done
	copy_script $0
	setup_certs
	load_image $IMG
	create_bridge
	echo -n "Installation complete. System can be started by using "
	echo "'sudo ${IMAGE} start' command"

elif [[ $1 == 'upgrade' ]]; then
	do_stop_deprecated
	if [[ -d $APP_PATH ]]; then 
		HASH=$(docker images -q ${IMAGE}:latest 2> /dev/null)
		# if hash is empty there is no need to perform version check
		if [[ $HASH != "" ]]; then
                        # get controller version by image hash
                        VERSION=$(docker images ${IMAGE} | grep $HASH | grep -v latest | awk '{print $2}')
                        # define by what version is going to be splitted
                        IFS=.
                        ary=($VERSION)
                        # IFS stands for "internal field separator". After IFS is set to any value,
                        # it remains that value. By default IFS consists of whitespace characters,
                        # so after using IFS - it must be reverted so that rest of variables
                        # wont be splitted
                        IFS=" "

                        # controller has to be started first for versions less than v.12 to count orgs correct
                        # for upgrade we need only arango and influx containers to be started.
                        for cont in arango influx; do
                                stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
                                case $stat in
                                        *"Exited"*)
                                                echo "To upgrade first start container with command 'sudo nftcontroller start ${PREFIX}${cont}'"
                                                exit 1
                                                ;;
                                        "")
                                                echo "To upgrade first start controller with command 'sudo ${IMAGE} start'"
                                                exit 1
                                                ;;
                                esac
                        done

                        # if there are >1 orgs present (which can be possible in controller version is less than v1.12) quit upgrade to save data
                        org_count=$(docker exec -it nftcontroller_arango arangosh --javascript.execute-string "db._listDatabases().forEach(function(db) { print(db); });" | grep org | wc -l)
                        if [[ ${org_count} -gt 1 && ${ary[1]} -lt 12 && ${ary[1]} != "" ]]; then
				echo -e "\033[0;31mWARNING:\033[0m the multi-organization feature is not supported in the newer version."
                                echo "Canceling setup..."
                                echo "Contact support regarding upgrade at support@ligowave.com."
                                exit 1
			fi
			# if installing from lower than 12, influx must be backuped before 
			# install and restored after so that new version of influx would work.
			# otherwise just install controller as usual 
			if [[ ${ary[1]} -lt 12 && ${ary[1]} != "" ]]; then 
				do_backup
				do_install
				migrate_configs
				do_restore
			else 
				do_install
				migrate_configs
                                # this message appears when upgrading from higher than v12
                                echo -n "Upgrade complete. If no error messages present system can be started by using: "
                                echo "'sudo ${IMAGE} start' command"
                                echo -n "if any error message is present upgrade again using: "
                                echo "'sudo ${INSTALL_NAME} upgrade' command"
			fi

		fi
	
	else
                echo "System is not installed. Please use 'sudo ${INSTALL_NAME} install'"
	fi

elif [[ $1 == 'info' ]]; then
	select_containers ${@:2}
	for cont in $selected; do
		stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
		if case $stat in *"Up"*) true;; *) false;; esac; then
			echo -e "\033[0;32m${cont}\033[0m"
			echo -n "     IP: "
			echo `docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
				$PREFIX$cont`
		else
			echo -e "\033[0;31m${cont}\033[0m"
		fi
	done
elif [[ $1 == 'status' ]]; then
	for cont in $CONTAINERS; do
		stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
		case $stat in
			*"Up"*)
				printf "%-15s \t\e[32mUP\e[39m\n" $cont
				;;
			*"Exited"*)
				printf "%-15s \t\e[33mCLOSED\e[39m\n" $cont
				;;
			*)
				printf "%-15s \t\e[31mDOWN\e[39m\n" $cont
				;;
		esac
	done
elif [[ $1 == 'export' ]]; then
	if [ -z $2 ]; then
		print_usage
	else
		for cont in $CONTAINERS; do
			stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
			case $stat in
				*"Up"*)
					echo "Please stop the system before using export command"
					exit 1
					;;
			esac
		done
		REAL_PATH=$(readlink -f $2)
		if [[ $REAL_PATH == "" ]]; then
			echo "Invalid path or file $2"
			exit 1
		fi
		export_lib $REAL_PATH
	fi
elif [[ $1 == 'import' ]]; then
	if [ -z $2 ]; then
		print_usage
	else
		for cont in $CONTAINERS; do
			stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
			case $stat in
				*"Up"*)
					echo "Please stop the system before using import command"
					exit 1
					;;
			esac
		done
		REAL_PATH=$(readlink -f $2)
		if [[ $REAL_PATH == "" ]]; then
			echo "Invalid path or file $2"
			exit 1
		fi
		import_lib $REAL_PATH
	fi
elif [[ $1 == 'uninstall' ]]; then
	for cont in $CONTAINERS; do
		stat=`docker ps -a --filter="name=${PREFIX}${cont}" --format '{{.Status}}'`
		case $stat in
			*"Up"*)
				echo "Please stop the system before uninstalling"
				exit 1
				;;
		esac
	done
	uninstall
elif [[ $1 == 'version' ]]; then
	container_version
else
	print_usage
fi
