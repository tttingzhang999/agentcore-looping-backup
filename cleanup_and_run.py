#!/usr/bin/env python3
"""
Cleanup auto-created delivery resources and run official observability script
"""

import boto3
import sys
import subprocess

def cleanup_existing_resources(runtime_id, region='ap-northeast-1'):
    """
    Delete auto-created delivery sources and destinations for the runtime
    so the official script can create its own
    """
    logs_client = boto3.client('logs', region_name=region)

    print("="*60)
    print("Step 1: Listing all delivery sources for runtime")
    print("="*60)

    # Get all delivery sources
    sources_response = logs_client.describe_delivery_sources()
    runtime_sources = []

    for source in sources_response['deliverySources']:
        for resource_arn in source['resourceArns']:
            if runtime_id in resource_arn:
                runtime_sources.append(source)
                print(f"Found: {source['name']} ({source['logType']})")

    if not runtime_sources:
        print("No auto-created delivery sources found. Proceeding to run script.")
        return True

    print(f"\nTotal sources to cleanup: {len(runtime_sources)}")
    print()

    # Step 2: Find and delete all deliveries using these sources
    print("="*60)
    print("Step 2: Deleting deliveries using these sources")
    print("="*60)

    deliveries_response = logs_client.describe_deliveries()
    deleted_deliveries = 0

    for delivery in deliveries_response['deliveries']:
        source_name = delivery['deliverySourceName']

        # Check if this delivery uses one of our sources
        if any(source['name'] == source_name for source in runtime_sources):
            try:
                logs_client.delete_delivery(id=delivery['id'])
                print(f"✓ Deleted delivery: {delivery['id']} (source: {source_name})")
                deleted_deliveries += 1
            except Exception as e:
                print(f"✗ Failed to delete delivery {delivery['id']}: {e}")
                return False

    print(f"\nDeleted {deleted_deliveries} deliveries")
    print()

    # Step 3: Delete the delivery sources
    print("="*60)
    print("Step 3: Deleting delivery sources")
    print("="*60)

    for source in runtime_sources:
        try:
            logs_client.delete_delivery_source(name=source['name'])
            print(f"✓ Deleted delivery source: {source['name']}")
        except Exception as e:
            print(f"✗ Failed to delete source {source['name']}: {e}")
            return False

    print()

    # Step 4: Delete delivery destinations if they exist
    print("="*60)
    print("Step 4: Deleting old delivery destinations (if any)")
    print("="*60)

    short_id = runtime_id.split('-')[-1]
    dest_names = [
        f"ultraCyan-{short_id}-logs",
        f"ultraCyan-{short_id}-traces"
    ]

    destinations_response = logs_client.describe_delivery_destinations()

    for dest_name in dest_names:
        dest_exists = any(d['name'] == dest_name for d in destinations_response['deliveryDestinations'])

        if dest_exists:
            try:
                logs_client.delete_delivery_destination(name=dest_name)
                print(f"✓ Deleted delivery destination: {dest_name}")
            except Exception as e:
                print(f"✗ Failed to delete destination {dest_name}: {e}")
        else:
            print(f"○ Destination does not exist: {dest_name}")

    print()
    print("="*60)
    print("✅ Cleanup completed successfully!")
    print("="*60)
    print()

    return True

if __name__ == "__main__":
    runtime_id = "solutionChatbotAgentCore_ultraCyan-Mi81qTDRE7"
    region = "ap-northeast-1"
    account_id = "593713876380"

    # Step 1: Cleanup existing resources
    print("Starting cleanup of auto-created resources...")
    print()

    success = cleanup_existing_resources(runtime_id, region)

    if not success:
        print("\n❌ Cleanup failed. Please check errors above.")
        sys.exit(1)

    # Step 2: Run the official observability script
    print("="*60)
    print("Running official observability enablement script...")
    print("="*60)
    print()

    try:
        result = subprocess.run(
            [sys.executable, 'enable_runtime_observability.py', runtime_id, region, account_id],
            check=True,
            capture_output=False
        )

        print("\n✅ All done! Observability has been enabled successfully.")
        sys.exit(0)

    except subprocess.CalledProcessError as e:
        print(f"\n❌ Official script failed with exit code {e.returncode}")
        sys.exit(1)
