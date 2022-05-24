#!/usr/bin/python
## Plotting script 
## Author: Matteo Varvello 
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import rcParams
rcParams.update({'figure.autolayout': True})
rcParams.update({'figure.autolayout': True})
rcParams.update({'errorbar.capsize': 2})
from pylab import *
import os
import subprocess
from urllib.parse import urlparse

# try a fast json parser if it is installed
try:
    import ujson as json
except BaseException:
    import json

# global parameters
light_green = '#90EE90'
color       = ['red', 'blue', light_green, 'magenta', 'black', 'purple', 'orange', 'yellow', 'pink']    # colors supported
style       = ['solid', 'dashed', 'dotted']              # styles of plots  supported
style       = ['solid', 'dashed', 'dotted', 'dashdot']
marker_list = ['v', 'h', 'D', '8', '+' ]                 # list of markers supported
width = 0.3   # width for barplot 
bar_colors   = ['red', 'blue', light_green, 'magenta', 'black', 'purple', 'orange', 'yellow', 'pink']    # colors supported
#bar_colors = ['orange', 'red', 'blue', 'darkorange', 'c', 'purple']
patterns = [ "", "o" , "+" , "x", "*" ]
iface = 'en0'
subnet = '192.168'
local_ipv4 = ''
orig_ip_v6  = '2607:fb90:2ed5:32f9:61a4:e4ef:4db1:11f7'
INITIAL_WINDOW_CUBIC = 10           # default initial congestion window used by Cubic
MSS = 1500                          # default maximum segment size 
DEBUG = False 
fixedRTT = 0

# increase font 
font = {'weight' : 'medium',
        'size'   : 16}
matplotlib.rc('font', **font)


# helper to convert devtools data into ms 
def convert_to_ms(val): 
    fields = str(val).split('.')
    return int(fields[0])*1000 + int(float(fields[1])/1000)

# helper to convert devtools data into ms 
def convert_from_ns_to_ms(val): 
    fields = str(val).split('.')
    return int(fields[0])*1000 + int(float(fields[1])/1000000)
   

# parse dummynet data 
def parseDummynet(logdata):
    data = {}
    delta = []
    delta_time = []
    prev = 0
    first = True 
    first_time = 0
    for line in logdata: 
        fields = line.split()
        
        # ignore uplink - NOTE: this is assuming experiments are on httplab network 
        if "192.168.8.8" in fields[3]: 
            continue
        
        # parse
        queue_id  = fields[3]
        time_val  = float(fields[0])
        bytes_rx  = float(fields[6])
        queue_val = float(fields[7])
        drop_val  =  float(fields[-1])
        
        # match queue id with SYN info or just use first queue value
        if first: 
            first_time = time_val
            first = False 
        
        # store data 
        if queue_id in data: 
            data[queue_id].append((time_val, queue_val, drop_val))
        else:     
            data[queue_id] = [(time_val, queue_val, drop_val)]
        if prev > 0: 
            delta_time.append((time_val - first_time)/1000)
            delta.append(time_val - prev)
        prev = time_val
        print(time_val, queue_val, bytes_rx)
        
    # all good
    return data, first_time, bytes_rx/1000

# add a vertical line 
def add_vertical_line(val, first_val, label, fs = 10, ls = 'dashed', shift_val = 0.02, use_min = True, col = 'black'):
    ax = plt.gca()
    ymin, ymax = ax.get_ylim()             
    t = (val - first_val)/1000                    
    curve = plt.axvline(x = t)
    plt.setp(curve, linewidth = 2, color = col, linestyle = 'dashed')
    if use_min: 
        ax.text(t + shift_val, ymin, label, fontsize = fs)
    else: 
        ax.text(t + shift_val, ymax, label, fontsize = fs)

# main goes here 
def main():           
        # read input params
        res_folder    = sys.argv[1]
        duration      = int(sys.argv[2])*1000
        test_id       = res_folder.split('/')[-1]
        prefix_short  = test_id      
        prefix        = res_folder + '/' + prefix_short
        dummynet_file = prefix + '.dummynet'                # file with dummynet data 
        
        # check that passed files exist and load them up 
        if not os.path.isfile(dummynet_file):
            print("File %s is missing" %(dummynet_file))
            return -1 
        with open(dummynet_file) as f:
            dummynetData = f.read().splitlines()       

        # create figure handlers
        fig_queue    = plt.figure()
        fig_drops    = plt.figure()
        fig_combined = plt.figure()            
        fig_dupack   = plt.figure()
        
        # load dummynet data
        dummynet_queue_dict, first_req_time, bytes_rx = parseDummynet(dummynetData)
        print("Bytes observed: %dKB" %(bytes_rx))
        with open(".bytes.txt", "w") as file: 
            file.write(str(bytes_rx))
        stop_tracing_time = first_req_time + duration 

        # plot dummynet data
        c_queue = 0
        c_drop = 0
        list_queues = []
        
        # with more queues, re-organize such to follow order of more imnportant sockets
        num_queues = len(dummynet_queue_dict)         
        
        # for this analysis, one queue only is used
        if num_queues > 1: 
            print("ERROR. Too many queues")
            return -1

        # iterate on the queue
        list_queues.append(next(iter(dummynet_queue_dict))) 
        for queue_id in list_queues:      
            dummynet_queue = dummynet_queue_dict[queue_id]
            first_time_drop = stop_tracing_time
            empty_queue = 0
            queue_time_vals = []
            queue_vals = []
            loss_vals = []
            queue_info_pos = []
            first = True
            loss_events = []
            if first_req_time == 0 or first_req_time == -1: 
                first_req_time = dummynet_queue[0][0]
            
            for i in dummynet_queue: 
                # trim based on info from previous script (if available)
                if i[0] > stop_tracing_time and stop_tracing_time != -1: 
                    break 
                
                # shift time based on first request
                t = (i[0]- first_req_time)/1000                 
                queue_time_vals.append(t)                
                queue_vals.append(i[1])

                # manage losses  
                loss_v = i[2]
                if len(loss_vals)>0 and loss_v != loss_vals[-1]:
                    if len(loss_events) == 0: 
                        with open(".slowstart.txt", "w") as file: 
                            file.write(str(i[0] - first_req_time))
                    loss_events.append((loss_v, i[0]))
                loss_vals.append(i[2])

                if t > 0: 
                    queue_info_pos.append((t, i[1]))
        
            if len(queue_info_pos) > 0:             
                # plot dummynet queue   
                plt.figure(fig_queue.number)
                curve = plot(queue_time_vals, queue_vals)
                plt.setp(curve, linewidth = 2, color = color[c_queue%len(color)], linestyle = style[int(c_queue/len(color))], label = queue_id, marker = marker_list[-1])
                c_queue += 1
                if num_queues == 1: 
                    plt.xticks(np.arange(0, max(queue_time_vals) + 1, 1.0))
                    ################ TEMP, be smarted here
                    #xlim((min(queue_time_vals)-0.1, 4))
                    #ylim((0, 60))
                    ################ TEMP                   
                    #add_vertical_line(syn_time, first_req_time, 'SYN', use_min = False, shift_val = -0.02) 
                    #add_vertical_line(first_req_time, first_req_time, 'GET')
                    #if first_time_drop != stop_tracing_time:
                    #    add_vertical_line(first_time_drop, first_req_time, 'First\nDrop')
                    #if time_first_dupack != -1: 
                    #    add_vertical_line(time_first_dupack, first_req_time, 'First\nLoss')
                
            # plot dummynet drops
            if len(loss_vals) > 0: 
                plt.figure(fig_drops.number)
                curve = plot(queue_time_vals, loss_vals)
                if num_queues == 1:                    
                    plt.xticks(np.arange(0, max(queue_time_vals) + 1, 1.0))            
                plt.setp(curve, linewidth = 2, color = color[c_drop%len(color)], linestyle = style[int(c_drop/len(color))], label = queue_id, marker = marker_list[-1])                    
                c_drop += 1
        
        # dummynet plots characteristics
        plt.figure(fig_queue.number)     
        if len(loss_events) > 0:   
            add_vertical_line(loss_events[0][1], first_req_time, "1stDROP", use_min = False)         
        xlabel('Time (sec)')
        ylabel('Dummynet Queue Length (#)')
        grid(True)
        ax = plt.gca()
        plt.legend(loc = 'best', prop={'size': 8})
        plt.xticks(fontsize = 8)
        plot_file = res_folder + '/' + prefix_short + '-dummynet-queue.png'
        savefig(plot_file)
        print("Check plot: ", plot_file)

        plt.figure(fig_drops.number)
        xlabel('Time (sec)')
        ylabel('Dummynet Drops (#)')
        grid(True)
        ax = plt.gca()
        plt.legend(loc = 'best', prop={'size': 8})
        plt.xticks(fontsize = 8)        
        plot_file = res_folder + '/' + prefix_short + '-dummynet-drops.png'
        savefig(plot_file)
        print("Check plot: ", plot_file)


# call main here
if __name__=="__main__":
    main()  