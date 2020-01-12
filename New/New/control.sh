#!/bin/bash

install_docker_compose() {
    echo -n "HA Web Application is containerized application and requires Docker Engine and Docker-compose server"
    echo "(https://www.docker.com/)"
    echo "sudo curl -L "https://github.com/docker/compose/releases/download/1.25.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose"
    echo "sudo chmod +x /usr/local/bin/docker-compose"
}

docker_status() {
    which docker-compose > /dev/null
    if [ $? != 0 ]; then
        echo "Docker-compose not installed. Please install latest stable Docker Compose server"
        install_docker_compose
        exit 1
    fi
    docker-compose ps &> /dev/null
    if [ $? != 0 ]; then
        echo "Could not connect to Docker deamon. Make sure Docker service is running."
        exit 1
    fi
    return 0
}

stop_service() {
    docker stop $1
    echo "Stopping ${1} container"
}
stop_system() {
    echo -n "Stopped docker-compose services\n"
    docker-compose stop
}

start_service() {
    echo "Starting ${1} container"
    docker start $1
}

start_system() {
    echo -n "Starting docker-compose services.\n"
    docker-compose up --build -d
}

restart_services() {
    echo -n "Restarting docker-compose services\n"
    docker-compose restart
}

install_images() {
    echo -n "Installing (building) required Docker Container Images"
    docker-compose build
}

up_services() {
    echo -n "Building containers from already installed Docker Images"
    docker-compose up
}

remove_service() {
    echo -n "Removing $1 container"
    docker stop $1
    docker rm $1
}

remove_all() {
    echo -n "Removing stopped containers"
    docker-compose rm -f
}

case "$1" in
    start)
    if [ -n $2 ]; then
        start_service $2
    else
        start_system
    fi
    ;;
    stop)
    if [ -n $2 ]; then
        stop_service $2
    else
        stop_system
    fi
    ;;
    remove)
    if [ -n $2 ]; then
        remove_service $2
    else
        remove_all
    fi
    ;;
    up)
        up_services
    ;;
    install)
        install_images
    ;;
esac