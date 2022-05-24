#!/bin/bash 
## Author: Matteo Varvello (varvello@brave.com)
## NOTES: tool for detecting delay-based congestion control algorithms
## Date: 06-5-2020

# load common functions across scripts
DEBUG=1
util_file="./common.sh"
if [ -f $util_file ]
then
    source $util_file
else
    echo "Util file $util_file is missing"
    exit 1
fi

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
function ctrl_c() {
	echo "Trapped CTRL-C"
	throttle_stop
	if [ $use_ping == "true " ]
	then
		killall ping 
	fi 
	echo "true"  > ".dummynet"
    sleep 1 
    echo "false"  > ".to_throttle"
    sleep 1 
	exit -1 
}

# usage 
usage(){
	echo "====================================================================================="
	echo "USAGE: $0 url test-id [MTU]"
	echo "====================================================================================="	
	echo "url: target URL to be tested (main object on a website)"
	echo "test-id: test-identifier to use"
	echo "[MTU: maximum transmission unit]"
	echo "====================================================================================="
}

# make sure no pending experiment is running
clean_previous(){
	myprint "Cleaning potential pending throttling" 
	throttle_stop
}

# function to derive appropriate throttling to trigger hystart
derive_throttling(){
	# parameters 
	MIN_RTT=100                # used to avoid too high speed to see things 
	MSS=$1                     # maximum segment size
	INITIAL_WINDOW=$2          # initial cwnd
	
	# pad latency to improve chance of consistent results across servers
	if [ $avg_rtt -lt $MIN_RTT ]
	then
		let "latency_padding=(MIN_RTT-avg_rtt)/2"
	else
		latency_padding=`python3 -c "import math; base=50; val=base*math.ceil($avg_rtt/base); padding=(val-$avg_rtt)/2; print(\"%d\" %(padding))"`
	fi 
	let "avg_rtt = avg_rtt + 2*latency_padding"
	latency_padding=$latency_padding"ms"	
	
	# burst derived from cubic default initial congestion window
	down_th=`python3 -c "val = ($INITIAL_WINDOW*$MSS*8)/($avg_rtt/1000)/(1000); print(\"%dKbs\" %(val))"`
	echo "DOWN_TH: $down_th"

	# all good 
	return 0 
}

# apply throttling either local or remote 
hystart_latency_increase(){
    delay=15
    throttle="true"
    increase=15
    max_delay=200
    echo $throttle > ".to_throttle"
    myprint "increasing throttling START"
    t_start_emu=`date +%s`

    # start increasing delay on ACKs
    while [ $throttle == "true" -a  $delay -lt $max_delay ]
    do
        sudo dnctl -q pipe 2 config delay ${delay}ms noerror
        sleep 0.1
        throttle=`cat ".to_throttle"`
        let "delay = delay + increase"
    done
    t_end_emu=`date +%s`
    let "t_passed = t_end_emu - t_start_emu"
    myprint "increasing throttling DONE -- Duration: $t_passed sec"
}

# check input 
if [ $# -lt 2 ]
then 
	usage
	exit -1 
fi 

# parameters 
id=`date +%s`                    # unique identifier for this test
router_throttling="false"        # flag to control local or router throttling 
MTU=500                          # default MTU
IW=10                            # initial congestion window size 

# input parameters
url=$1   
id=$2    
if [ $# -eq 3 ]
then
	MTU=$3
fi 


#MTU configuration
sudo ifconfig en0 mtu $MTU
networksetup -getMTU en0

# disable SACKs
sudo sysctl -w net.inet.tcp.sack=0
  
# folder organization 
res_folder="./hystart-light/$id"       # folder where results go 
mkdir -p $res_folder 

# logging input (and SSID)
SSID=`/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport -I  | grep -w "SSID:" | cut -f 2 -d ":" | sed s/" "//`
myprint "$0 URL: $url RES-FOLDER: $res_folder SSID: $SSID MTU: $MTU"

# make sure no pending experiment is running
clean_previous

# derive IP and AVG_RTT from ping 
myprint "Derive IP via dig and AVG_RTT from $num_pings PING..."
domain=`echo "$url" | awk -F "/" '{print $3}'`
num_pings=3
ping -c $num_pings $domain > .log-ping 2>&1 
cat .log-ping | grep "Request timeout for icmp_seq" > /dev/null 
if [ $? -eq 0 ]
then 
	test_IP=`dig $domain | grep -A 5 "ANSWER SECTION" |awk '{if($4=="A" && found==0){print $NF; found=1;}}'`
	myprint "PING not allowed. Attempting HTTPING to $test_IP"
	httping -c $num_pings $test_IP > .log-ping 2>&1
	avg_rtt=`cat .log-ping | grep max | cut -f 2 -d "=" | cut -f 2 -d "/"`
	avg_rtt=`python3 -c "val = $avg_rtt/2; print(int(val))"`
	IP=`cat .log-ping | grep connected | head -n 1 | cut -f 3 -d " " | cut -f 1 -d ":"`
else 
	avg_rtt=`cat .log-ping | grep "stddev" | cut -f 2 -d "=" | cut -f 2 -d "/" | cut -f 1 -d "."`
	IP=`cat .log-ping | grep -v "PING" | head -n 1 | cut -f 4 -d " "`
fi 
myprint "Domain: $domain IP: $IP AVG_RTT: $avg_rtt ms"
if [ -z $avg_rtt ]
then 
	echo "ERROR. Something went wrong measuring RTT. Interrupting"
	exit -1 
fi 

# derive required throttling 
derive_throttling $MTU $IW

# uncomment below to use a target value instead of what derived by derive_throttling
#down_th="1200Kbps"	 #MTU 1500
#down_th="200Kbps"	 #MTU 500
unlimited_up="100000Kbps"
myprint "[throttle_start] UP_BDW: $unlimited_up DOWN_BDW: $down_th PADDING_LATENCY: $latency_padding LOSSES: 0 TARGET_RTT: ${avg_rtt}ms"
queue_size=100
throttle_start $unlimited_up $down_th $latency_padding 0 $queue_size

# continuos slowdown -- seem useless
#hystart_latency_increase &

# start monitoring dummynet queue 
log_queue=$res_folder"/"$id".dummynet"
echo $log_queue
monitor_queue $log_queue &

# keep track of current bytes received
ibytes_start=`netstat -ib -I en0 | grep svarvel | awk '{print $7}'`

# launch curl 
key_grep="curl"
max_wait_load=60
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.122 Safari/537.36"
myprint "Launching CURL - URL: $url"	 
start_time=$(($(gdate +%s%N)/1000000))
curl_stats=`timeout $max_wait_load curl -w "%{time_starttransfer}\t%{size_download}" "$url" -H 'pragma: no-cache' -H 'cache-control: no-cache' -H 'user-agent: $UA' -o /dev/null 2>/dev/null`
end_time=$(($(gdate +%s%N)/1000000))
t_start_transfer=`echo "$curl_stats" | cut -f 1`
num_rtts=`echo "$start_time $end_time $t_start_transfer $avg_rtt" | awk '{num_rtts=($2-($1+1000*$3))/$4}END{print num_rtts}'`
let "dur = end_time - start_time"
myprint "CURL stats: $curl_stats Duration: $dur Num-RTTs: $num_rtts"

# check how many bytes received via OS
ibytes_now=`netstat -ib -I en0 | grep "svarvel" | awk '{print $7}'`
ans=`echo "$ibytes_start $ibytes_now" | awk '{delta=($2-$1)/1000000; printf("%.2f MB\t", delta)}'`
let "raw_bytes = ibytes_now - ibytes_start"
myprint "BytesInStart: $ibytes_start BytesInNow: $ibytes_now BytesInDelta: $ans"

# stop dummynet queue monitoring (and continuous slowdown)
echo "true" > ".dummynet"
sleep 2
echo "false"  > ".to_throttle"

# stop throttling
myprint "Removing local throttling - ALWAYS, just to be safe"
throttle_stop

#re-enable SACKs and MTU 
sudo sysctl -w net.inet.tcp.sack=1
sudo ifconfig en0 mtu 1500
networksetup -getMTU en0

# plotting
myprint "python3 analyzer-queue-light.py $res_folder $dur"
rm ".slowstart.txt" > /dev/null 2>&1
rm ".bytes.txt" > /dev/null 2>&1
timeout 30 python3 analyzer-queue-light.py $res_folder $dur

# detection
delay_threshold=2500    
MIN_DATA=100    
if [ ! -f ".bytes.txt" ]
then 
    myprint "Something went wrong. Bytes file is missing!"
    exit -1 
fi 
bytes_val=`cat ".bytes.txt"`
if [ -f ".slowstart.txt" ]
then
    val=`cat ".slowstart.txt"`
    label=`echo $val" "$delay_threshold | awk '{if ($1<$2) print "LOSSBASED"; else print("DELAYBASED")}'`
    val=$val"ms"
else 
    val="-1"
    label="DELAYBASED"
    b_val=`echo $bytes_val | cut -f 1 -d "."`                        
    if [ $b_val -lt $MIN_DATA ] 
    then 
        label="TOOSMALL"
    fi 
fi 
# logging 
echo -e "${url}\t${val}\t${bytes_val}KB\t${label}" 
