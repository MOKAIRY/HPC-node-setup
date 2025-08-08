#!/bin/bash

shared_path="/home/sync"

mkdir -p $shared_path
touch $shared_path/users.new $shared_path/groups.new $shared_path/shadow.new

user_output="$shared_path/users.new" 
group_output="$shared_path/groups.new" 
shadow_output="$shared_path/shadow.new" 
users_file="/etc/passwd"
groups_file="/etc/group"
shadow_file="/etc/shadow"


while read -r line; do
  uid=$(echo "$line" | awk -F: '{print $3}')
  uname=$(echo "$line" | awk -F: '{print $1}')
  if [ "$uid" -ge 1000 ]; then
    sed -i "/^$uname:/d" $user_output
    echo "$line" >> $user_output
  fi
  
done < $users_file

while read -r line; do
  gid=$(echo "$line" | awk -F: '{print $3}')
  gname=$(echo "$line" | awk -F: '{print $1}')
  if [ "$gid" -ge 1000 ]; then
    sed -i "/^$gname:/d" $group_output
    echo "$line" >> $group_output
  fi
  
done < $groups_file

while read -r line; do
  uname=$(echo "$line" | awk -F: '{print $1}')
  uid=$(id -u $uname)

  if [ "$uid" -ge 1000 ]; then
    sed -i "/^$uname:/d" $shadow_output
    echo "$line" >> $shadow_output
  fi
done < $shadow_file


echo "Done. Output written to:"
echo "  $user_output"
echo "  $group_output"
echo " $shadow_output"
