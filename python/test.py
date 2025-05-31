#! /usr/bin/env python3

import json
patchObj = [{
    "op": "replace",
    "path": "/status",
    "value": {
        "phase": "Completed",
        "message": "Great success",
    }
}]
