#!/bin/bash
echo "$HOSTNAME" > /usr/share/nginx/html/index.html

exec nginx -g "daemon off;"
