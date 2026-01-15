#!/usr/bin/env python3
"""
Enable observability for AgentCore Runtime
Based on: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html Section 7
"""

import boto3
import sys

def enable_observability_for_resource(resource_arn, resource_id, account_id, region='ap-northeast-1'):
    """
    Enable observability for a Bedrock AgentCore resource (Runtime)

    Args:
        resource_arn: Full ARN of the runtime (e.g., arn:aws:bedrock-agentcore:ap-northeast-1:123456789012:runtime/runtime-id)
        resource_id: Runtime ID (e.g., solutionChatbotAgentCore_ultraCyan-Mi81qTDRE7)
        account_id: AWS account ID
        region: AWS region
    """
    logs_client = boto3.client('logs', region_name=region)

    print(f"Enabling observability for runtime: {resource_id}")
    print(f"Resource ARN: {resource_arn}")
    print(f"Region: {region}")
    print()

    # Step 0: Create new log group for vended log delivery
    log_group_name = f'/aws/vendedlogs/bedrock-agentcore/{resource_id}'
    try:
        logs_client.create_log_group(logGroupName=log_group_name)
        print(f"✓ Created log group: {log_group_name}")
    except logs_client.exceptions.ResourceAlreadyExistsException:
        print(f"✓ Log group already exists: {log_group_name}")
    except Exception as e:
        print(f"✗ Failed to create log group: {e}")
        return None

    log_group_arn = f'arn:aws:logs:{region}:{account_id}:log-group:{log_group_name}'

    # Step 1: Create delivery source for logs
    print("\nStep 1: Creating APPLICATION_LOGS delivery source...")
    try:
        logs_source_response = logs_client.put_delivery_source(
            name=f"{resource_id}-logs-source",
            logType="APPLICATION_LOGS",
            resourceArn=resource_arn
        )
        print(f"✓ Created logs source: {logs_source_response['deliverySource']['name']}")
    except logs_client.exceptions.ConflictException:
        print(f"✓ Logs source already exists: {resource_id}-logs-source")
    except Exception as e:
        print(f"✗ Failed to create logs source: {e}")
        return None

    # Step 2: Create delivery source for traces
    print("\nStep 2: Creating TRACES delivery source...")
    try:
        traces_source_response = logs_client.put_delivery_source(
            name=f"{resource_id}-traces-source",
            logType="TRACES",
            resourceArn=resource_arn
        )
        print(f"✓ Created traces source: {traces_source_response['deliverySource']['name']}")
    except logs_client.exceptions.ConflictException:
        print(f"✓ Traces source already exists: {resource_id}-traces-source")
    except Exception as e:
        print(f"✗ Failed to create traces source: {e}")
        return None

    # Step 3: Create delivery destinations (use short names due to 60 char limit)
    # Extract last 8 chars of runtime ID for uniqueness
    short_id = resource_id.split('-')[-1]  # e.g., Mi81qTDRE7

    logs_dest_name = f"ultraCyan-{short_id}-logs"
    traces_dest_name = f"ultraCyan-{short_id}-traces"

    print(f"\nStep 3a: Creating CloudWatch Logs delivery destination ({logs_dest_name})...")
    try:
        logs_destination_response = logs_client.put_delivery_destination(
            name=logs_dest_name,
            deliveryDestinationType='CWL',
            deliveryDestinationConfiguration={
                'destinationResourceArn': log_group_arn,
            }
        )
        print(f"✓ Created logs destination: {logs_destination_response['deliveryDestination']['name']}")
        logs_dest_arn = logs_destination_response['deliveryDestination']['arn']
    except logs_client.exceptions.ConflictException:
        print(f"✓ Logs destination already exists: {logs_dest_name}")
        # Get existing destination ARN
        destinations = logs_client.describe_delivery_destinations()
        for dest in destinations['deliveryDestinations']:
            if dest['name'] == logs_dest_name:
                logs_dest_arn = dest['arn']
                break
    except Exception as e:
        print(f"✗ Failed to create logs destination: {e}")
        return None

    # Traces required
    print(f"\nStep 3b: Creating X-Ray delivery destination ({traces_dest_name})...")
    try:
        traces_destination_response = logs_client.put_delivery_destination(
            name=traces_dest_name,
            deliveryDestinationType='XRAY'
        )
        print(f"✓ Created traces destination: {traces_destination_response['deliveryDestination']['name']}")
        traces_dest_arn = traces_destination_response['deliveryDestination']['arn']
    except logs_client.exceptions.ConflictException:
        print(f"✓ Traces destination already exists: {traces_dest_name}")
        # Get existing destination ARN
        destinations = logs_client.describe_delivery_destinations()
        for dest in destinations['deliveryDestinations']:
            if dest['name'] == traces_dest_name:
                traces_dest_arn = dest['arn']
                break
    except Exception as e:
        print(f"✗ Failed to create traces destination: {e}")
        return None

    # Step 4: Create deliveries (connect sources to destinations)
    print("\nStep 4a: Creating APPLICATION_LOGS delivery...")
    try:
        logs_delivery = logs_client.create_delivery(
            deliverySourceName=f"{resource_id}-logs-source",
            deliveryDestinationArn=logs_dest_arn
        )
        print(f"✓ Created logs delivery: {logs_delivery['delivery']['id']}")
        logs_delivery_id = logs_delivery['delivery']['id']
    except logs_client.exceptions.ConflictException:
        print(f"✓ Logs delivery already exists")
        # Find the delivery ID
        deliveries = logs_client.describe_deliveries()
        for d in deliveries['deliveries']:
            if d['deliverySourceName'] == f"{resource_id}-logs-source":
                logs_delivery_id = d['id']
                print(f"  Delivery ID: {logs_delivery_id}")
                break
    except Exception as e:
        print(f"✗ Failed to create logs delivery: {e}")
        return None

    # Traces required (CRITICAL for aws/spans)
    print("\nStep 4b: Creating TRACES delivery (CRITICAL for aws/spans)...")
    try:
        traces_delivery = logs_client.create_delivery(
            deliverySourceName=f"{resource_id}-traces-source",
            deliveryDestinationArn=traces_dest_arn
        )
        print(f"✓ Created traces delivery: {traces_delivery['delivery']['id']}")
        traces_delivery_id = traces_delivery['delivery']['id']
    except logs_client.exceptions.ConflictException:
        print(f"✓ Traces delivery already exists")
        # Find the delivery ID
        deliveries = logs_client.describe_deliveries()
        for d in deliveries['deliveries']:
            if d['deliverySourceName'] == f"{resource_id}-traces-source":
                traces_delivery_id = d['id']
                print(f"  Delivery ID: {traces_delivery_id}")
                break
    except Exception as e:
        print(f"✗ Failed to create traces delivery: {e}")
        return None

    print("\n" + "="*60)
    print("✅ Observability enabled successfully!")
    print("="*60)
    print(f"Runtime: {resource_id}")
    print(f"Logs delivery ID: {logs_delivery_id}")
    print(f"Traces delivery ID: {traces_delivery_id}")
    print("\nTraces will now flow: Runtime → X-Ray → aws/spans log group")
    print("\nNext steps:")
    print("1. Wait 2-3 minutes for configuration to propagate")
    print("2. Invoke the agent to generate traces")
    print("3. Check aws/spans log group for trace data")

    return {
        'logs_delivery_id': logs_delivery_id,
        'traces_delivery_id': traces_delivery_id
    }

if __name__ == "__main__":
    # Runtime configuration
    runtime_id = "solutionChatbotAgentCore_ultraCyan-Mi81qTDRE7"
    region = "ap-northeast-1"
    account_id = "593713876380"
    resource_arn = f"arn:aws:bedrock-agentcore:{region}:{account_id}:runtime/{runtime_id}"

    # Allow override via command line arguments
    if len(sys.argv) > 1:
        runtime_id = sys.argv[1]
    if len(sys.argv) > 2:
        region = sys.argv[2]
    if len(sys.argv) > 3:
        account_id = sys.argv[3]
    if len(sys.argv) > 1:
        resource_arn = f"arn:aws:bedrock-agentcore:{region}:{account_id}:runtime/{runtime_id}"

    result = enable_observability_for_resource(resource_arn, runtime_id, account_id, region)

    if result:
        print(f"\n✅ Done! Delivery IDs: {result}")
        sys.exit(0)
    else:
        print(f"\n❌ Failed to enable observability")
        sys.exit(1)
