# Same Ubuntu version as the VM setup for consistency
FROM ubuntu:26.04

# Reduce interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install SSH, benchmarking and networking tools, compilers, and other utilities
RUN apt-get update && apt-get install -y \
    openssh-server openssh-client \
    sysbench stress-ng iozone3 iperf3 openmpi-bin hpcc \
    netcat-openbsd iputils-ping iproute2 net-tools nano gcc make \
    && rm -rf /var/lib/apt/lists/*

# Create the user 'user01' with home directory and set password to 'pass'
RUN useradd -m -s /bin/bash user01 && echo "user01:pass" | chpasswd

# Create necessary directories for SSH and shared storage, set permissions for 'user01'
RUN mkdir -p /run/sshd /shared && chown user01:user01 /shared

# Expose SSH port and copy the entrypoint script
EXPOSE 22
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]