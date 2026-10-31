#!/bin/bash
# Spec 476 — the one base image every template is a layer on. Sourced by
# build-templates.sh and build-lamp-matrix.sh; scripts/lamp-release-verify.py
# names the same root (TEMPLATE_ROOT).
TEMPLATE_BASE_NAME=studio-desktop
TEMPLATE_BASE_QCOW="devshot-guest-${TEMPLATE_BASE_NAME}.qcow2"
TEMPLATE_BASE_MANIFEST="devshot-guest-${TEMPLATE_BASE_NAME}.json"
