FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_PRIORITY=critical

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       samba \
       samba-ad-dc \
       samba-ad-provision \
       krb5-user \
       smbclient \
       ldap-utils \
       dnsutils \
       iproute2 \
       acl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/lib/samba

CMD ["tail", "-f", "/dev/null"]
