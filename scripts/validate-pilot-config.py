#!/usr/bin/env python3
"""Validate non-secret iOS archive settings before invoking Xcode."""
import ipaddress
import os
import re
from urllib.parse import urlsplit

def validate_endpoint(value):
    try:
        url = urlsplit(value)
        port = url.port
    except ValueError as error:
        raise ValueError('ARRIVAU_API_URL must be a valid HTTPS origin') from error
    host = (url.hostname or '').lower().rstrip('.')
    if (url.scheme != 'https' or not host or url.username is not None or url.password is not None
            or url.query or url.fragment or url.path not in ('', '/')
            or any(c.isspace() for c in value) or '\\' in value
            or host == 'localhost' or host.endswith('.localhost')
            or host.endswith('.local') or '$(' in value or port == 0):
        raise ValueError('ARRIVAU_API_URL must be a remote HTTPS root origin without credentials, query or fragment')
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', host) or '.' not in host or '..' in host:
            raise ValueError('Use a DNS name or routable IP for ARRIVAU_API_URL')
    else:
        if address.is_loopback or address.is_unspecified or address.is_link_local or address.is_multicast:
            raise ValueError('ARRIVAU_API_URL cannot be a loopback, unspecified, link-local or multicast address')
    return value.rstrip('/')

def validate_archive(env):
    validate_endpoint(env.get('ARRIVAU_API_URL', ''))
    if not re.fullmatch(r'[A-Z0-9]{10}', env.get('ARRIVAU_TEAM_ID', '')):
        raise ValueError('Set ARRIVAU_TEAM_ID to your ten-character Apple Developer team ID')
    bundle = env.get('ARRIVAU_BUNDLE_ID', '')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle) or bundle.startswith('dev.arrivau.'):
        raise ValueError('Set ARRIVAU_BUNDLE_ID to your own registered reverse-DNS bundle identifier')
    if not re.fullmatch(r'[1-9][0-9]*', env.get('ARRIVAU_BUILD_NUMBER', '')):
        raise ValueError('Set ARRIVAU_BUILD_NUMBER to a new positive integer for each upload')

if __name__ == '__main__':
    try:
        validate_archive(os.environ)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print('Pilot archive configuration is valid (no credentials required)')
