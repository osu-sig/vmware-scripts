#!/bin/bash

# This script is a wrapper around checklogin.pl
# On a login failure, send an event to pagerduty.
#
# SERVICE_KEY is a pagerduty service key

VCENTER=vcenter.somewhere.com
SERVICE_KEY=changeme
INCIDENT_FILE=/tmp/checklogin.incident
 
source $HOME/.bashrc

echo `date`

$HOME/vmware-scripts/checklogin.pl --server $VCENTER
RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo "Success"
    if [ -e $INCIDENT_FILE ]; then
        rm $INCIDENT_FILE
    fi
elif [ ! -e $INCIDENT_FILE ]; then
    RESPONSE=$(curl -s -H "Content-type: application/json" -X POST \
    -d '{ "service_key": "'$SERVICE_KEY'", "event_type": "trigger", "description": "ERROR logging in to vCenter", "details": { "vCenter": "'$VCENTER'", "username": "sig_vma" } }' \
    "https://events.pagerduty.com/generic/2010-04-15/create_event.json")
    echo "$RESPONSE" > "$INCIDENT_FILE"
else
    echo "Failed, but incident already logged"
fi
