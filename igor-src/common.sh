# load common functions across scripts
DEBUG=1
util_file="./util.cfg"
if [ -f $util_file ]
then
    source $util_file
else
    echo "Util file $util_file is missing"
    exit 1
fi
pfctl_path="pfctl.rules" 

# clean file if it exists
clean_file(){
	if [ -f $1 ]
	then 
		rm $1
	fi 
}

# start remote TCP collection 
remote_TCP_start(){	
	trace_file=$1
	server=$2
	max_duration=$3
	#MY_IP=`curl ifconfig.co`   
	MY_IP="98.109.116.129"     #MY_IP="98.109.67.217"	
	command="sh -c 'cd http2-tests; nohup ./socket-monitoring.sh $max_duration $trace_file $MY_IP > /dev/null 2>&1 &'"	
	#command="sh -c 'cd http2-tests; nohup ./socket-monitoring.sh $max_duration traces/$trace_file> /dev/null 2>&1 &'"		
	myprint "Starting remote socket monitoring -- ssh -n -f $erver $command"
	ssh -n -f $remote_server $command
} 

# stop socket monitoring
remote_TCP_stop(){
    trace_file=$1
	server=$2	
    command="killall socket-monitoring.sh"
    myprint "Stopping remote socket monitoring: $command"
    ssh $server $command    
    command="cd http2-tests; gzip $trace_file &"
    myprint "GZIP remote file - $command"    
    ssh $server $command  
}

# collect remote TCP and clean data remotely
remote_TCP_collect(){
	trace_file=$1 
	server=$2
	myprint "Trace collection: $trace_file"	
	scp $server:"http2-tests/"$trace_file".gz" $res_folder	
	myprint "Cleaning remote log..."
	command="rm http2-tests/$trace_file.gz"
	ssh $remote_server $command  
}

# background connection monitoring
background_monitoring(){
	to_run=`cat .radio-status`
	logfile=$1
	
	# clean log
	adb logcat -c

	# https://android.stackexchange.com/questions/74952/interpretting-the-output-of-dumpsys-telephony-registry
	echo "Starting background monitoring of radio signal. Logfile: $logfile" 
	while [ $to_run == "true" ] 
	do 
		#line=`adb shell dumpsys telephony.registry | grep "mSignalStrength" | grep Signal | cut -f 2 -d ":" | awk '{print "mLteSignalStrength:"$8"\tmLteRsrp:"$9"\tmLteRsrq:"$10"\tmLteRssnr:"$11"\tmLteCqi:"$12}'`
		line=`adb shell dumpsys telephony.registry | grep "mSignalStrength" | grep "Signal"`		
		echo -e `date +%s`"\t"$line >> $logfile
		sleep 3
		to_run=`cat .radio-status`	
	done

	# get current location 
	#adb shell dumpsys location | grep "Location" | grep "passive" > $logfile
	
	# logging 
	echo "Done with background monitoring of radio signal"
}

# helper function to execute command on rasberry pi
execute_remote_command(){
	router="httplab"
	echo "Executing command <<"$1">> at $router"
	ssh $router "$1"
}

# load URLs to test
load_urls(){
	num_urls=0
	first="true"
	resume="false"
	if [ $# -eq 3 ]
	then 
		resume="true"
		resume_url=$3
	fi 
	while read line || [ -n "$line" ] # EOF is detected as it reads the last "line" + returns error status which prevents loop 
	do  
		# stop if passed MAX requested
		if [ $num_urls -ge $2 ]
		then 
			break 
		fi 
		u=`echo "$line" | cut -f 1 -d ","`
		
		# check if we are resuming from a previous run
		if [ $resume == "true" ]
		then 
			if [ "$u" != "$resume_url" ]
			then 
				continue
			else 
				resume="false"
			fi 
		fi
		
		# verify URL is https
		if [[ $u == *"https"* ]]
		then
			url_list[$num_urls]="$u"
			let "num_urls++"
		else
			echo "Skipping $u since not HTTPS"
		fi 
	done < $1 
}

# wait for ligthouse to be ready 
wait_lighthouse(){
	found=1
	max_waiting=30
	t_s_wait=`date +%s`
	while  [ $found -ne 0 ]
	do
		t_c_wait=`date +%s`
		let "t_p_wait = t_c_wait - t_s_wait"
		if [ $t_p_wait -gt $max_waiting ]
		then
			myprint "wait_lighthouse timeout"
			return 1 
			break 
		fi 
		if [ -f $1 ]
		then
			# NOTE: this fail in case of warmup (Brave, to load up adblocker)
			#cat $1 | grep "Beginning devtoolsLog and trace"
			cat $1 | grep "Loading page" | grep "CSSUsage"
			found=$?
		fi 
		sleep 0.01
	done

	# all good 
	return 0 
}


# wait on an experiment to be done 
wait_experiment(){
	t_s=`date +%s`
	key_grep=$1
	domain=$2
	found=0
	while [ $found -eq 0 ]
	do 
		ps aux | grep "$key_grep" | grep -v "rtt-monitor" | grep "$domain" | grep -v grep > /dev/null 2>&1
		found=$?
		sleep 1 
	done
	t_e=`date +%s`
	let "t_p = t_e - t_s"
	myprint "$1 completed. Duration: $t_p"
}

# monitor RTT via ping
rtt_monitor(){
	(./rtt-monitor.sh $1 $2 &)
	#(ping $1 | while read pong; do echo "$(($(gdate +%s%N)/1000000)) $pong"; done > $2 2>&1 &)
}

# monitor duymmynet queue 
monitor_queue(){
	my_ip=`ifconfig | grep -A 5 en0 | grep inet  | awk '{print $2}'`
	myprint "Dummynet queue monitoring -- START ($1) -- MYIP: $my_ip"
	echo "false" > ".dummynet"
	isDone=`cat .dummynet`
	while [ $isDone == "false" ] 
	do 
		date_ms=$(($(gdate +%s%N)/1000000))
		#sudo dnctl show queue  >> "log-queue" 2>&1   
		#sudo dnctl show queue 2>&1 | awk -v ip="$my_ip" '{if($4 ~ip) print $0}' > ".queue-log"
		#sudo dnctl show queue | grep "192.168" > ".queue-log"
		sudo dnctl show queue | grep -v 'mask\|BKT\|droptail' > ".queue-log"
		while read queue_info
		do 
			echo -e "$date_ms\t$queue_info" >> $1
		done < ".queue-log"
		#sleep 0.01
		isDone=`cat .dummynet`
	done 
	myprint "Dummynet queue monitoring -- DONE"

	# further filtering on $1
	ip_to_filter=`tail -n 10 $1| awk '{if($7>MAX){MAX=$7; IP=$5;}}END{print(IP)}'`
	cp $1 "$1.full"
	cat $1 | awk -v ip=$ip_to_filter '{if($5==ip) print $0}' > t 
	mv t $1
}

# monitor duymmynet queue 
monitor_queue_light(){
	my_ip=`ifconfig | grep -A 5 en0 | grep inet  | awk '{print $2}'`
	myprint "Dummynet queue monitoring -- START ($1) -- MYIP: $my_ip"
	echo "false" > ".dummynet"
	isDone=`cat .dummynet`
	while [ $isDone == "false" ] 
	do 
		date_ms=$(($(gdate +%s%N)/1000000))
		sudo dnctl show queue | grep -v 'mask\|BKT\|droptail' > ".queue-log"
		while read queue_info
		do 
			echo -e "$date_ms\t$queue_info" >> $1
		done < ".queue-log"
		sleep 0.05
		isDone=`cat .dummynet`
	done 
	myprint "Dummynet queue monitoring -- DONE"

	# further filtering on $1
	ip_to_filter=`tail -n 10 $1| awk '{if($7>MAX){MAX=$7; IP=$5;}}END{print(IP)}'`
	cp $1 "$1.full"
	cat $1 | awk -v ip=$ip_to_filter '{if($5==ip) print $0}' > t 
	mv t $1
}

throttle_stop () {
	sudo dnctl -q flush
	sudo dnctl -q pipe flush
	sudo pfctl -f /etc/pf.conf > /dev/null 2>&1
	sudo pfctl -q -E > /dev/null 2>&1
	sudo pfctl -q -d
}

throttle_start () {
	uplink=$1
	downlink=$2
	delay=$3
	loss=$4
	echo "Applying throttling -- UP: $uplink DOWN: $downlink DELAY: $delay LOSS: $loss"
	
	sudo dnctl -q flush
	sudo dnctl -q pipe flush
	sudo dnctl -q pipe 1 config delay 0ms noerror
	sudo dnctl -q pipe 2 config delay 0ms noerror
	sudo pfctl -f ${pfctl_path} > /dev/null 2>&1
	sudo dnctl -q pipe 1 config bw $uplink delay $delay plr $loss noerror
	sudo dnctl -q pipe 2 config bw $downlink delay $delay plr $loss noerror
	sudo pfctl -E > /dev/null 2>&1
}

