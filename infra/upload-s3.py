#!/usr/bin/env python3
"""
Upload script for Buoys media files to S3.
Uses boto3 directly — no Docker needed.
Install: pip3 install boto3
"""

import os
import sys
import boto3
from pathlib import Path

# Configuration
AWS_ACCESS_KEY_ID = os.environ.get('AWS_ACCESS_KEY_ID', '')
AWS_SECRET_ACCESS_KEY = os.environ.get('AWS_SECRET_ACCESS_KEY', '')
AWS_DEFAULT_REGION = os.environ.get('AWS_DEFAULT_REGION', 'eu-west-1')
BUCKET_NAME = os.environ.get('S3_BUCKET_NAME', 'buoys-media-files')
TRACKS_DIR = Path(__file__).parent.parent / 'tracks'

def main():
    if not AWS_ACCESS_KEY_ID or not AWS_SECRET_ACCESS_KEY:
        print("ERROR: Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables")
        sys.exit(1)

    # Check boto3
    try:
        import boto3
    except ImportError:
        print("ERROR: boto3 not installed. Run: pip3 install boto3")
        sys.exit(1)

    if not TRACKS_DIR.exists():
        print(f"ERROR: Source directory '{TRACKS_DIR}' not found")
        sys.exit(1)

    print(f"Target bucket: s3://{BUCKET_NAME}")
    print(f"Source directory: {TRACKS_DIR}")
    print("")

    # Create S3 client
    s3 = boto3.client(
        's3',
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        region_name=AWS_DEFAULT_REGION
    )

    # Clean up old files in tracks/ prefix
    print(f"Cleaning up old files in s3://{BUCKET_NAME}/tracks/ ...")
    existing = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix='tracks/')
    if 'Contents' in existing:
        delete_keys = [{'Key': obj['Key']} for obj in existing['Contents']]
        s3.delete_objects(Bucket=BUCKET_NAME, Delete={'Objects': delete_keys})
        print(f"  Deleted {len(delete_keys)} old files")
    print("")

    # Upload files with clean names
    uploads = [
        ('hero-bg-video.mp4', 'tracks/hero-bg-video.mp4'),
        ('session-dobrichlapci-track-1.wav', 'tracks/session-dobrichlapci-track-1.wav'),
        ('session-dobrichlapci-track-2.wav', 'tracks/session-dobrichlapci-track-2.wav'),
        ('session-dobrichlapci-track-3.wav', 'tracks/session-dobrichlapci-track-3.wav'),
        ('session-dobrichlapci-track-4.wav', 'tracks/session-dobrichlapci-track-4.wav'),
        ('session-dobrichlapci-track-5.wav', 'tracks/session-dobrichlapci-track-5.wav'),
        ('session-dobrichlapci-track-6.wav', 'tracks/session-dobrichlapci-track-6.wav'),
        ('session-dobrichlapci-track-7.wav', 'tracks/session-dobrichlapci-track-7.wav'),
        ('speedstop.mp3', 'tracks/speedstop.mp3'),
        ('okupe.mp3', 'tracks/okupe.mp3'),
    ]

    # Find actual files in tracks directory
    files = list(TRACKS_DIR.glob('*'))
    print(f"Found {len(files)} files in {TRACKS_DIR}")
    print("")

    # Map files by pattern
    file_map = {}
    for f in files:
        name = f.name.lower()
        if 'hero' in name:
            file_map['hero-bg-video.mp4'] = f
        elif 'speedstop' in name:
            file_map['speedstop.mp3'] = f
        elif 'okupe' in name:
            file_map['okupe.mp3'] = f
        elif 'buoys-session' in name or 'session' in name:
            # Session tracks — sort and assign
            pass

    # Handle session tracks — only wav/mp3/mp4, skip .asd etc.
    session_files = sorted([
        f for f in files 
        if ('session' in f.name.lower() or 'buoys-session' in f.name.lower())
        and f.suffix.lower() in ['.wav', '.mp3', '.mp4']
    ])
    for i, f in enumerate(session_files[:7], 1):
        file_map[f'session-dobrichlapci-track-{i}.wav'] = f

    # Upload each file with the correct destination key
    for dest_name, local_path in uploads:
        if dest_name in file_map and file_map[dest_name].exists():
            src = file_map[dest_name]
            print(f"  Uploading {src.name} -> {dest_name}...")
            s3.upload_file(
                str(src),
                BUCKET_NAME,
                local_path,  # use the clean destination path
                ExtraArgs={'ContentType': 'application/octet-stream'}
            )
            print(f"    ✓ Done")
        else:
            print(f"  SKIP {dest_name} (source file not found)")

    print("")
    print("========================================")
    print("  Upload complete!")
    print("========================================")
    print("")
    print(f"Files in s3://{BUCKET_NAME}/tracks/:")
    for obj in s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix='tracks/').get('Contents', []):
        print(f"  {obj['Key']}")

if __name__ == '__main__':
    main()