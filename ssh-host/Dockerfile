FROM debian:latest

ARG IIQ_USER=iiq
ARG IIQ_UID=1005

RUN rm /bin/sh && ln -s /bin/bash /bin/sh

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y openssh-server sudo nano && \
    mkdir /var/run/sshd

RUN groupadd ${IIQ_USER} && useradd --no-log-init -u ${IIQ_UID} -g ${IIQ_USER} ${IIQ_USER} && usermod -aG sudo iiq
RUN echo iiq:iiq | chpasswd 

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
