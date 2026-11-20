#!/bin/bash
set -e

# Print a message to indicate the container is starting and show its role (e.g., master, worker)
echo "Container starting with role: $NODE_ROLE"

# Define the path to the SSH directory for user01
SSH_DIR=/home/user01/.ssh

# Create the SSH directory if it doesn't exist (for storing SSH keys and configuration)
mkdir -p $SSH_DIR

# Copy the public SSH key to authorized_keys to allow passwordless authentication for user01
cp /ssh-keys/id_ed25519.pub $SSH_DIR/authorized_keys

# Only on the master node: copy the private SSH key, so master can connect to workers via SSH
if [ "$NODE_ROLE" = "master" ]; then
    cp /ssh-keys/id_ed25519 $SSH_DIR/id_ed25519
fi

# Write SSH client configuration to skip host key checking and avoid storing known hosts
printf 'Host *\n\tStrictHostKeyChecking no\n\tUserKnownHostsFile /dev/null\n' > $SSH_DIR/config

# Set the ownership of everything in the SSH directory to user01
chown -R user01:user01 $SSH_DIR

# Set correct permissions: 700 for the SSH directory, 600 for all files inside it
chmod 700 $SSH_DIR
chmod 600 $SSH_DIR/*
chmod 777 /shared 

# Run the SSH daemon in the foreground with debug output, so that the container stays alive
exec /usr/sbin/sshd -D -e