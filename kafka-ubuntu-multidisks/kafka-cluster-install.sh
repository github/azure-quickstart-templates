#!/bin/bash

### Cognosys Technologies
### 
### Warning! This script partitions and formats disk information be careful where you run it
###          This script is currently under development and has only been tested on Ubuntu images in Azure
###          This script is not currently idempotent and only works for provisioning at the moment

### Remaining work items
### -Alternate discovery options (Azure Storage)
### -Implement Idempotency and Configuration Change Support
### -Implement OS Disk Striping Option (Currenlty using multiple kafka data paths)
### -Implement Non-Durable Option (Put data on resource disk)
### -Configure Work/Log Paths
### -Recovery Settings (These can be changed via API)

help()
{
    #TODO: Add help text here
    echo "This script installs kafka cluster on Ubuntu"
    echo "Parameters:"
    echo "-k kafka version like 0.8.2.1"
    echo "-b broker id"
    echo "-h view this help content"
    echo "-z zookeeper not kafka"
    echo "-i zookeeper Private IP address prefix"
}

log()
{
	# If you want to enable this logging add a un-comment the line below and add your account key 
    	#curl -X POST -H "content-type:text/plain" --data-binary "$(date) | ${HOSTNAME} | $1" https://logs-01.loggly.com/inputs/[account-key]/tag/redis-extension,${HOSTNAME}
	echo "$1"
}

log "Begin execution of kafka script extension on ${HOSTNAME}"

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

#Format the data disk
bash vm-disk-utils-0.1.sh -s

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "${HOSTNAME}" /etc/hosts
if [ $? -eq $SUCCESS ];
then
  echo "${HOSTNAME}found in /etc/hosts"
else
  echo "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 $(hostname)" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etc/hosts"
fi

#Script Parameters
KF_VERSION="0.8.2.1"
BROKER_ID=0
ZOOKEEPER1KAFKA0="0"

ZOOKEEPER_IP_PREFIX="10.0.1.10"
INSTANCE_COUNT=1
ZOOKEEPER_PORT="2181"
KAFKADIR="/var/lib/kafkadir"
# sed command issues need escape character \
KAFKADIRSED="\/var\/lib\/kafkadir"

#Loop through options passed
while getopts :k:b:z:i:c:p:h optname; do
    log "Option $optname set with value ${OPTARG}"
  case $optname in
    k)  #kafka version
      KF_VERSION=${OPTARG}
      ;;
    b)  #broker id
      BROKER_ID=${OPTARG}
      ;;
    z)  #zookeeper not kafka
      ZOOKEEPER1KAFKA0=${OPTARG}
      ;;
    i)  #zookeeper Private IP address prefix
      ZOOKEEPER_IP_PREFIX=${OPTARG}
      ;;
    c) # Number of instances
	INSTANCE_COUNT=${OPTARG}
	;;
    h)  #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 2
      ;;
  esac
done

# Install Oracle Java
install_java()
{
    log "Installing Java"
    add-apt-repository -y ppa:webupd8team/java
    apt-get -y update 
    echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
    apt-get -y install oracle-java7-installer
}

# Expand a list of successive IP range defined by a starting address prefix (e.g. 10.0.0.1) and the number of machines in the range
# 10.0.0.1-3 would be converted to "10.0.0.10 10.0.0.11 10.0.0.12"

expand_ip_range_for_server_properties() {
    IFS='-' read -a HOST_IPS <<< "$1"
    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        echo "server.$(expr ${n} + 1)=${HOST_IPS[0]}${n}:2888:3888" >> zookeeper-3.4.6/conf/zoo.cfg       
    done
}

function join { local IFS="$1"; shift; echo "$*"; }

expand_ip_range() {
    IFS='-' read -a HOST_IPS <<< "$1"

    declare -a EXPAND_STATICIP_RANGE_RESULTS=()

    for (( n=0 ; n<("${HOST_IPS[1]}"+0) ; n++))
    do
        HOST="${HOST_IPS[0]}${n}:${ZOOKEEPER_PORT}"
                EXPAND_STATICIP_RANGE_RESULTS+=($HOST)
    done

    echo "${EXPAND_STATICIP_RANGE_RESULTS[@]}"
}

# Install Zookeeper - can expose zookeeper version
install_zookeeper()
{
	mkdir -p /var/lib/zookeeper
	cd /var/lib/zookeeper
	wget "http://mirrors.ukfast.co.uk/sites/ftp.apache.org/zookeeper/stable/zookeeper-3.4.6.tar.gz"
	tar -xvf "zookeeper-3.4.6.tar.gz"

	touch zookeeper-3.4.6/conf/zoo.cfg

	echo "tickTime=2000" >> zookeeper-3.4.6/conf/zoo.cfg
	echo "dataDir=/var/lib/zookeeper" >> zookeeper-3.4.6/conf/zoo.cfg
	echo "clientPort=2181" >> zookeeper-3.4.6/conf/zoo.cfg
	echo "initLimit=5" >> zookeeper-3.4.6/conf/zoo.cfg
	echo "syncLimit=2" >> zookeeper-3.4.6/conf/zoo.cfg
	# OLD Test echo "server.1=${ZOOKEEPER_IP_PREFIX}:2888:3888" >> zookeeper-3.4.6/conf/zoo.cfg
	$(expand_ip_range_for_server_properties "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}")

	echo $(($1+1)) >> /var/lib/zookeeper/myid

	zookeeper-3.4.6/bin/zkServer.sh start
}

# Setup datadisks
setup_datadisks() {

	MOUNTPOINT="/datadisks/disk1"

	# Move database files to the striped disk
	if [ -L ${KAFKADIR} ];
	then
		logger "Symbolic link from ${KAFKADIR} already exists"
		echo "Symbolic link from ${KAFKADIR} already exists"
	else
		logger "Moving  data to the $MOUNTPOINT/kafkadir"
		echo "Moving Kafka data to the $MOUNTPOINT/kafkadir"
		mv ${KAFKADIR} $MOUNTPOINT/kafkadir

		# Create symbolic link so that configuration files continue to use the default folders
		logger "Create symbolic link from ${KAFKADIR} to $MOUNTPOINT/kafkadir"
		ln -s $MOUNTPOINT/kafkadir ${KAFKADIR}
	fi
}

# Install kafka
install_kafka()
{
	cd /usr/local
	name=kafka
	version=${KF_VERSION}
	#this Kafka version is prefix same used for all versions
	kafkaversion=2.10
	description="Apache Kafka is a distributed publish-subscribe messaging system."
	url="https://kafka.apache.org/"
	arch="all"
	section="misc"
	license="Apache Software License 2.0"
	package_version="-1"
	src_package="kafka_${kafkaversion}-${version}.tgz"
	download_url=http://mirror.sdunix.com/apache/kafka/${version}/${src_package} 

	rm -rf kafka
	mkdir -p kafka
	cd kafka
	#_ MAIN _#
	if [[ ! -f "${src_package}" ]]; then
	  wget ${download_url}
	fi
	tar zxf ${src_package}
	cd kafka_${kafkaversion}-${version}
	
	sed -r -i "s/(broker.id)=(.*)/\1=${BROKER_ID}/g" config/server.properties 
	sed -r -i "s/(zookeeper.connect)=(.*)/\1=$(join , $(expand_ip_range "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}"))/g" config/server.properties 
	sed -r -i "s/(log.dirs)=(.*)/\1=${KAFKADIR}/g" config/server.properties 

	chmod u+x /usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh
	/usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh /usr/local/kafka/kafka_${kafkaversion}-${version}/config/server.properties &
}

# Primary Install Tasks
#########################
#NOTE: These first three could be changed to run in parallel
#      Future enhancement - (export the functions and use background/wait to run in parallel)

#Install Oracle Java
#------------------------
install_java

if [ ${ZOOKEEPER1KAFKA0} -eq "1" ];
then
	#
	#Install zookeeper
	#-----------------------
	install_zookeeper
else
	#
	#Install kafka
	#-----------------------
	mkdir ${KAFKADIR}
	setup_datadisks
	install_kafka
fi
