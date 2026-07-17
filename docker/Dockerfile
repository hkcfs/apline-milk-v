FROM ubuntu:noble

ENV DOCKER_BUILD=true

RUN mkdir /project
WORKDIR /project
COPY scripts/setup.sh /project/
RUN /project/setup.sh
RUN git clone https://github.com/pengutronix/genimage
WORKDIR /project/genimage
RUN ./autogen.sh && ./configure && make && make install
WORKDIR /project

# Copy project files
COPY build.sh /project/
COPY scripts/ /project/scripts/
COPY genimage.cfg /project/
COPY multi.its.in /project/
COPY milkv-bootloader /project/milkv-bootloader/
COPY kernel/ /project/kernel/
COPY packages/ /project/packages/
RUN chmod +x /project/build.sh /project/scripts/*.sh
