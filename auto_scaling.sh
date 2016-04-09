#!/bin/sh

source "$(cd $(dirname $0); pwd)/settings.sh"

__GSLB_MAX_HOST_COUNT=6 #さくらのクラウドの仕様上,GSLBへの登録は最大6台まで
__SCALE_MACHINE_NAME_PATTERN="$MACHINE_NAME_PATTERN-client"
__MASTER_MACHINE="$MACHINE_NAME_PATTERN-$MASTER_MACHINE_NAME"

export MACHINE_LIST_INFO_DIR
export DOCKER
export DOCKER_MACHINE
export DOCKER_COMPOSE
export CALC_CPU_DOCKER_COMPOSE_PATH
export WEB_APP_COMPOSE_PATH
export __MASTER_MACHINE
export __SCALE_MACHINE_NAME_PATTERN
export SAKURACLOUD_ACCESS_TOKEN
export SAKURACLOUD_ACCESS_TOKEN_SECRET
export SAKURACLOUD_REGION
export SAKURACLOUD_MASTER_NODE_ID
export SAKURACLOUD_GSLB

#****************************
# Functions
#****************************

validateSettings() {
  if [ -z "$DOCKER_COMPOSE" ]; then
    echo >&2 '$DOCKER_COMPOSE is not set. Please set $DOCKER_COMPOSE'
    exit 1
  fi
  if [ -z "$DOCKER_MACHINE" ]; then
    echo >&2 '$DOCKER_MACHINE is not set. Please set $DOCKER_MACHINE'
    exit 1
  fi

  if [ -z "$SAKURACLOUD_ACCESS_TOKEN" ]; then
    echo >&2 '$SAKURACLOUD_ACCESS_TOKEN is not set. Please set $SAKURACLOUD_ACCESS_TOKEN'
    exit 1
  fi 
  
  if [ -z "$SAKURACLOUD_ACCESS_TOKEN_SECRET" ]; then
    echo >&2 '$SAKURACLOUD_ACCESS_TOKEN_SECRET is not set. Please set $SAKURACLOUD_ACCESS_TOKEN_SECRET'
    exit 1
  fi 

  if [ $IS_SETUP_MASTER != "1" ] && [ -z "$SAKURACLOUD_MASTER_NODE_ID" ]; then
    echo >&2 '$SAKURACLOUD_MASTER_NODE_ID is not set. Please set $SAKURACLOUD_MASTER_NODE_ID'
    exit 1
  fi

  if [ -z "$SAKURACLOUD_REGION" ]; then
    export SAKURACLOUD_REGION="is1a"
  fi

  if [ -z "$SAKURACLOUD_GSLB" ]; then
    echo >&2 '$SAKURACLOUD_GSLB is not set. Please set $SAKURACLOUD_GSLB'
    exit 1
  fi 

  if [ -z "$MACHINE_NAME_PATTERN" ]; then
    echo >&2 '$MACHINE_NAME_PATTERN is not set. Please set $MACHINE_NAME_PATTERN'
    exit 1
  fi 
  
  if [ $MAX_SCALE_COUNT -ge $__GSLB_MAX_HOST_COUNT ]; then
    echo >&2 '$MAX_SCALE_COUNT should be <'"$__GSLB_MAX_HOST_COUNT"
    exit 1
  fi
}

setupMasterNode(){
  if [ $IS_SETUP_MASTER == "1" ] ; then
    local MASTER_NODE=`$DOCKER_MACHINE ls -q --filter "name=$__MASTER_MACHINE"`
    if [ -z $MASTER_NODE ]; then
      $DOCKER_MACHINE create -d sakuracloud $DOCKER_MACHINE_SCALEOUT_OPTIONS $__MASTER_MACHINE ; \
      (eval $($DOCKER_MACHINE env $__MASTER_MACHINE);$DOCKER_COMPOSE -f $WEB_APP_COMPOSE_PATH/docker-compose.yml  up -d ) ;
    fi

    export SAKURACLOUD_MASTER_NODE_ID=`$DOCKER_MACHINE inspect -f "{{.Driver.ID}}" $__MASTER_MACHINE`
  fi

}

createMachineInfoFile() {
	TARGET=$1
	SERVER_INFO=( `$DOCKER_MACHINE inspect -f "{{.Driver.ID}} {{.Driver.Client.AccessToken}} {{.Driver.Client.AccessTokenSecret}} {{.Driver.Client.Region}}" $TARGET ` )
	echo -n "" > "${MACHINE_LIST_INFO_DIR}/${SERVER_INFO[0]}"
	echo "export SACLOUD_ACCESS_TOKEN=${SERVER_INFO[1]}" >> "$MACHINE_LIST_INFO_DIR/${SERVER_INFO[0]}"
	echo "export SACLOUD_ACCESS_TOKEN_SECRET=${SERVER_INFO[2]}" >> "$MACHINE_LIST_INFO_DIR/${SERVER_INFO[0]}"
	echo "export SACLOUD_REGION=${SERVER_INFO[3]}" >> "$MACHINE_LIST_INFO_DIR/${SERVER_INFO[0]}"
}
export -f createMachineInfoFile

createMachineInfoFiles() {
  if [ -e "$MACHINE_LIST_INFO_DIR" ]; then
    rm -Rf "$MACHINE_LIST_INFO_DIR"
  fi

  mkdir -p "$MACHINE_LIST_INFO_DIR"

  #マスターノードの分の設定ファイル
  echo "" > "${MACHINE_LIST_INFO_DIR}/${SAKURACLOUD_MASTER_NODE_ID}"
  echo "export SACLOUD_ACCESS_TOKEN=${SAKURACLOUD_ACCESS_TOKEN}" >> "$MACHINE_LIST_INFO_DIR/${SAKURACLOUD_MASTER_NODE_ID}"
  echo "export SACLOUD_ACCESS_TOKEN_SECRET=${SAKURACLOUD_ACCESS_TOKEN_SECRET}" >> "$MACHINE_LIST_INFO_DIR/${SAKURACLOUD_MASTER_NODE_ID}"
  echo "export SACLOUD_REGION=${SAKURACLOUD_REGION}" >> "$MACHINE_LIST_INFO_DIR/${SAKURACLOUD_MASTER_NODE_ID}"

  #すでに起動しているクラウドノード分の設定ファイル
  $DOCKER_MACHINE ls -q --filter "name=$__SCALE_MACHINE_NAME_PATTERN*" | xargs -L1 -I{} /bin/bash -c 'createMachineInfoFile {}'
}

scaleIn(){
  local MACHINE_COUNT=$1
  $DOCKER_MACHINE rm -f "$__SCALE_MACHINE_NAME_PATTERN$MACHINE_COUNT"
}

scaleOut(){
  local MACHINE_COUNT=$(( $1 + 1 ))
  local MACHINE_NAME="$__SCALE_MACHINE_NAME_PATTERN$MACHINE_COUNT"
  $DOCKER_MACHINE create -d sakuracloud $DOCKER_MACHINE_SCALEOUT_OPTIONS $MACHINE_NAME ; \
  (eval $($DOCKER_MACHINE env $MACHINE_NAME);$DOCKER_COMPOSE -f $WEB_APP_COMPOSE_PATH/docker-compose.yml  up -d )
}

#****************************
# Main
#****************************

CURRENT_DIR=$(cd $(dirname $0); pwd)
if [ -e "$CURRENT_DIR/.env" ]; then
  source "$CURRENT_DIR/.env"
fi

# 入力検証
validateSettings

# 基本マシン(Masterノード)確認
setupMasterNode

# 対象マシン名リスト(docker-machineにて収集)
createMachineInfoFiles

#**************
#メトリクス集計
#**************
CURRENT_DATE=`date "+%Y/%m/%d %H:%M:%S"`
STR_DATE="$CURRENT_DATE"

#マシン台数
CURRENT_MACHINE_COUNT=$(( `ls "$MACHINE_LIST_INFO_DIR" | wc -l ` ))
CURRENT_SCALE_MACHINE_COUNT=$(( `$DOCKER_MACHINE ls -q --filter "name=$__SCALE_MACHINE_NAME_PATTERN*" | wc -l` ))

if [ $CURRENT_MACHINE_COUNT -le 0 ] ; then
  echo "error:Machines not found."
  exit 2
fi

#各マシンのCPU時間を取得して合計
TOTAL_CPU_TIME=$( \
ls "$MACHINE_LIST_INFO_DIR" | \
xargs -L1 -I'{}' /bin/bash -c '( \
    . $MACHINE_LIST_INFO_DIR/{} ; \
    eval $($DOCKER_MACHINE env $__MASTER_MACHINE); \
    $DOCKER_COMPOSE -f $CALC_CPU_DOCKER_COMPOSE_PATH/docker-compose.yml run sacloud-cputime {})' | \
awk '{sum+=$1}END{print sum}' )

#**************
# 判定
#**************
CPU_AVG=`echo "scale=5; $TOTAL_CPU_TIME / $CURRENT_MACHINE_COUNT" | bc | sed -e 's/^\./0./g'`

echo "CURRENT_TIME               : $STR_DATE"
echo "TOTAL_CPU_TIME             : $TOTAL_CPU_TIME"
echo "CPU_AVG                    : $CPU_AVG"
echo "CURRENT_TOTAL_MACHINE_COUNT: $CURRENT_MACHINE_COUNT"
echo "CURRENT_SCALE_MACHINE_COUNT: $CURRENT_SCALE_MACHINE_COUNT"

if [ `echo "$CPU_AVG > $CPU_TIME_SCALE_OUT_THRESHOLD" | bc ` == 1 ] && [ $CURRENT_SCALE_MACHINE_COUNT -lt $MAX_SCALE_COUNT ]; then
  echo "****ScaleOut...****"
  scaleOut $CURRENT_SCALE_MACHINE_COUNT
  echo "****Done.****"

elif [ `echo "$CPU_AVG < $CPU_TIME_SCALE_IN_THRESHOLD" | bc ` == 1 ] && [ $CURRENT_SCALE_MACHINE_COUNT -gt 0 ]; then
  echo "****ScaleIn...****"
  scaleIn $CURRENT_SCALE_MACHINE_COUNT
  echo "****Done.****"
fi

echo "Done."

exit 0
