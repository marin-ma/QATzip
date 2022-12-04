#! /bin/bash
################################################################
#   BSD LICENSE
#
#   Copyright(c) 2007-2022 Intel Corporation. All rights reserved.
#   All rights reserved.
#
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions
#   are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in
#       the documentation and/or other materials provided with the
#       distribution.
#     * Neither the name of Intel Corporation nor the names of its
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
################################################################

set -e
echo "***QZ_ROOT run_perf_test.sh start"

rm -f result_comp_stderr
rm -f result_decomp_stderr

CURRENT_PATH=`dirname $(readlink -f "$0")`

#check whether test exists
if [ ! -f "$QZ_ROOT/test/test" ]; then
    echo "$QZ_ROOT/test/test: No such file. Compile first!"
    exit 1
fi

#get the type of QAT hardware
platform=`lspci | grep Co-processor | awk '{print $6}' | head -1`
if [[ $platform != "37c8" && $platform != "4940" ]]
then
    platform=`lspci | grep Co-processor | awk '{print $5}' | head -1`
    if [[ $platform != "DH895XCC" && $platform != "C62x" ]]
    then
        platform=`lspci | grep Co-processor | awk '{print $7}' | head -1`
        if [ $platform != "C3000" ]
        then
            echo "Unsupport Platform: `lspci | grep Co-processor` "
            exit 1
        fi
    fi
fi
echo "platform=$platform"


#Replace the driver configuration files and configure hugepages
echo "Replace the driver configuration files and configure hugepages."
if [[ $platform = "37c8" || $platform = "C62x" ]]
then
    process=24
    \cp $CURRENT_PATH/config_file/c6xx/c6xx_dev0.conf /etc
    \cp $CURRENT_PATH/config_file/c6xx/c6xx_dev1.conf /etc
    \cp $CURRENT_PATH/config_file/c6xx/c6xx_dev2.conf /etc
elif [ $platform = "DH895XCC" ]
then
    process=8
    \cp $CURRENT_PATH/config_file/dh895xcc/dh895xcc_dev0.conf /etc
elif [ $platform = "4940" ]
then
    process=$NUM_P
    fp=$(($NUM_P / 2))
    if [ $NUM_P = 1 ]
    then
      fp=1
    fi
    ft=$((64 / $fp))
    conf_file=$CURRENT_PATH/config_file/4xxx/${fp}x${ft}.conf
    echo "use conf file: $conf_file"
    \cp -f $conf_file $CURRENT_PATH/config_file/4xxx/4xxx_dev0.conf
    \cp -f $conf_file $CURRENT_PATH/config_file/4xxx/4xxx_dev1.conf
    \cp $CURRENT_PATH/config_file/4xxx/4xxx*.conf /etc
elif [ $platform = "C3000" ]
then
    process=4
    \cp $CURRENT_PATH/config_file/c3xxx/c3xxx_dev0.conf /etc
fi

thread=4
if [ $platform = "4940" ]
then
    thread=$NUM_T
fi

service qat_service restart
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
rmmod usdm_drv
insmod $ICP_ROOT/build/usdm_drv.ko max_huge_pages=1024 max_huge_pages_per_process=$((1024/$process))
sleep 5

#Perform performance test
echo "Perform performance test"
echo "Process: $process x Threads: $thread"

loop="10000"
loop_min="1000"
loop_max="100000"
extra_arg="-m 4 -t $thread -B 0"

output_prefix=${process}x${thread}_result
if [ $INPUT_TAG ]
then
  output_prefix=${INPUT_TAG}"_"${output_prefix}
fi

if [[ ! -z $QZ_POLLING_MODE && $QZ_POLLING_MODE == "BUSY" ]]
then
  extra_arg=${extra_arg}" -P busy"
  output_prefix=${output_prefix}"_busy"
fi

if [ $INPUT_FILE ]
then
  input_file_szb=`du -b $INPUT_FILE | awk '{print $1}'`
  echo "Input file size in bits: "$input_file_szb
  gb_threshold=$(( 1 << 30 ))
  mb_threshold=$(( 1 << 20 ))
  if [ $input_file_szb -lt $gb_threshold ] && [ $thread -lt 16 ]
  then
    loop_=$(( $gb_threshold / $input_file_szb * 2 ))
    if [ $loop_ -gt $loop_max ]
    then
      loop=$loop_max
    elif [ $loop_ -gt $loop ]
    then
      loop=$loop_
    fi
  elif [ $input_file_szb -ge $mb_threshold ] && [ $thread -gt 16 ]
  then
    loop=$loop_min
  fi
  extra_arg=${extra_arg}" -i $INPUT_FILE -l $loop"
else
  extra_arg=${extra_arg}" -l $loop"
fi
echo "extra arg: $extra_arg"

function comp() {
  output=$output_prefix"_comp"
  echo > $output
  cpu_list=2
  for((numProc_comp = 0; numProc_comp < $process; numProc_comp ++))
  do
      taskset -c $cpu_list $QZ_ROOT/test/test -D comp ${extra_arg} >> $output 2>> result_comp_stderr &
      cpu_list=$(($cpu_list + 1))
  done
  wait
  compthroughput=`awk '{sum+=$8} END{print sum}' $output`
  head -n2 $output
  tail -n1 $output
  echo "compthroughput=$compthroughput Gbps"
}

function decomp() {
  output=$output_prefix"_decomp"
  echo > $output
  cpu_list=1
  for((numProc_decomp = 0; numProc_decomp < $process; numProc_decomp ++))
  do
      taskset -c $cpu_list $QZ_ROOT/test/test -D decomp ${extra_arg} >> $output 2>> result_decomp_stderr &
      cpu_list=$(($cpu_list + 1))
  done
  wait
  decompthroughput=`awk '{sum+=$8} END{print sum}' $output`
  head -n2 $output
  tail -n1 $output
  echo "decompthroughput=$decompthroughput Gbps"
}

if [[ ! -z $QZ_DECOMP && $QZ_DECOMP == "TRUE" ]]
then
  time decomp
else
  time comp
fi

# rm -f result_comp
# rm -f result_decomp
echo "***QZ_ROOT run_perf_test.sh end"
echo "####################################################################################################"
echo ""
echo ""
