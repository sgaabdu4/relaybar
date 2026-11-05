FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session openssh-server curl ca-certificates sudo && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash homeuser && mkdir -p /home/homeuser/.ssh && chmod 700 /home/homeuser/.ssh && chown -R homeuser:homeuser /home/homeuser/.ssh && systemctl enable ssh
USER homeuser
STOPSIGNAL 37
CMD ["/sbin/init"]
