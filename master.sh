#!/bin/bash

set -o errexit

# 判断系统版本
check_sys(){
    local checkType=$1
    local value=$2

    local release=''
    local systemPackage=''
    local packageSupport=''

    if [[ "$release" == "" ]] || [[ "$systemPackage" == "" ]] || [[ "$packageSupport" == "" ]];then
        if [[ -f /etc/redhat-release ]];then
            release="centos"
            systemPackage="yum"
            packageSupport=true
        elif cat /etc/issue | grep -q -E -i "debian";then
            release="debian"
            systemPackage="apt"
            packageSupport=true
        elif cat /etc/issue | grep -q -E -i "ubuntu";then
            release="ubuntu"
            systemPackage="apt"
            packageSupport=true
        elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat";then
            release="centos"
            systemPackage="yum"
            packageSupport=true
        elif cat /proc/version | grep -q -E -i "debian";then
            release="debian"
            systemPackage="apt"
            packageSupport=true
        elif cat /proc/version | grep -q -E -i "ubuntu";then
            release="ubuntu"
            systemPackage="apt"
            packageSupport=true
        elif cat /proc/version | grep -q -E -i "centos|red hat|redhat";then
            release="centos"
            systemPackage="yum"
            packageSupport=true
        else
            release="other"
            systemPackage="other"
            packageSupport=false
        fi
    fi

    echo -e "release=$release\nsystemPackage=$systemPackage\npackageSupport=$packageSupport\n" > /tmp/ezhttp_sys_check_result

    if [[ $checkType == "sysRelease" ]]; then
        if [ "$value" == "$release" ];then
            return 0
        else
            return 1
        fi

    elif [[ $checkType == "packageManager" ]]; then
        if [ "$value" == "$systemPackage" ];then
            return 0
        else
            return 1
        fi

    elif [[ $checkType == "packageSupport" ]]; then
        if $packageSupport;then
            return 0
        else
            return 1
        fi
    fi
}

# 安装依赖
install_depend() {
    if check_sys sysRelease ubuntu;then
        apt-get update
        apt-get -y install wget python-minimal
    elif check_sys sysRelease centos;then
        yum install -y wget python
    fi    
}

get_sys_ver() {
    cat > /tmp/sys_ver.py <<EOF
import platform
import re

sys_ver = platform.platform()
sys_ver = re.sub(r'.*-with-(.*)-.*',"\g<1>",sys_ver)
if sys_ver.startswith("centos-7"):
    sys_ver = "centos-7"
if sys_ver.startswith("centos-6"):
    sys_ver = "centos-6"
print(sys_ver)
EOF
    echo `python /tmp/sys_ver.py`
}

download(){
    local url1=$1
    local url2=$2
    local filename=$3

    speed1=`curl -m 5 -L -s -w '%{speed_download}' "$url1" -o /dev/null || true`
    speed1=${speed1%%.*}
    speed2=`curl -m 5 -L -s -w '%{speed_download}' "$url2" -o /dev/null || true`
    speed2=${speed2%%.*}
    echo "speed1:"$speed1
    echo "speed2:"$speed2
    url="$url1\n$url2"
    if [[ $speed2 -gt $speed1 ]]; then
        url="$url2\n$url1"
    fi
    echo -e $url | while read l;do
        echo "using url:"$l
        wget --dns-timeout=5 --connect-timeout=5 --read-timeout=10 --tries=2 "$l" -O $filename && break
    done
}

sync_time(){
    echo "start to sync time and add sync command to cronjob..."

    if check_sys sysRelease ubuntu || check_sys sysRelease debian;then
        apt-get -y update
        apt-get -y install ntpdate wget
        /usr/sbin/ntpdate -u pool.ntp.org || true
        ! grep -q "/usr/sbin/ntpdate -u pool.ntp.org" /var/spool/cron/crontabs/root > /dev/null 2>&1 && echo '*/10 * * * * /usr/sbin/ntpdate -u pool.ntp.org > /dev/null 2>&1 || (date_str=`curl update.cdnfly.cn/common/datetime` && timedatectl set-ntp false && echo $date_str && timedatectl set-time "$date_str" )'  >> /var/spool/cron/crontabs/root
        service cron restart
    elif check_sys sysRelease centos; then
        yum -y install ntpdate wget
        /usr/sbin/ntpdate -u pool.ntp.org || true
        ! grep -q "/usr/sbin/ntpdate -u pool.ntp.org" /var/spool/cron/root > /dev/null 2>&1 && echo '*/10 * * * * /usr/sbin/ntpdate -u pool.ntp.org > /dev/null 2>&1 || (date_str=`curl update.cdnfly.cn/common/datetime` && timedatectl set-ntp false && echo $date_str && timedatectl set-time "$date_str" )' >> /var/spool/cron/root
        service crond restart
    fi

    # 时区
    rm -f /etc/localtime
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

    if /sbin/hwclock -w;then
        return
    fi 
}

# 直接指定版本
VER="v5.6.13"
tar_gz_name="cdnfly-agent-${VER}-centos-7.tar.gz"

install_depend
get_sys_ver
sync_time

# 解析命令行参数
TEMP=`getopt -o h --long help,ver:,no-mysql,only-mysql,no-es,only-es,master-ip:,es-ip:,es-dir:,es-pwd:,mysql-ip:,ignore-ntp -- "$@"`
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi
eval set -- "$TEMP"

while true ; do
    case "$1" in
        -h|--help) help ; exit 1 ;;
        --ver) VER=$2 ; shift 2 ;;
        --) shift ; break ;;
        *) break ;;
    esac
done

cd /opt/
download "https://github.com/cnaws/cdn/raw/main/$tar_gz_name" "https://github.com/cnaws/cdn/raw/main/master/$tar_gz_name" "$tar_gz_name"

tar xf $tar_gz_name
rm -rf cdnfly
mv cdnfly-agent-$VER cdnfly

# 开始安装
cd /opt/cdnfly
chmod +x install.sh
./install.sh $@

if [ -f /opt/cdnfly/view/upgrade.so ]; then
    sed -i "s/https:\/\/update.cdnfly.cn\//http:\/\/auth.cdnfly.cn\/\/\/\//g" /opt/cdnfly/view/upgrade.so
    supervisorctl -c /opt/cdnfly/conf/supervisord.conf reload
fi

