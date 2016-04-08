FROM alpine:3.3
MAINTAINER Kazumichi Yamamoto <yamamoto.febc@gmail.com>

RUN set -x && \ 
    apk add --update --no-cache \ 
      curl \
      coreutils \
      jq

COPY sacloud_get_cputime.sh /sacloud_get_cputime.sh
ENTRYPOINT ["/sacloud_get_cputime.sh"]
