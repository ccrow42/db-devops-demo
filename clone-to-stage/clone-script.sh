#!/bin/bash

# Variables (Adjust these according to your setup)
NAMESPACE="pxbbq-prod"  # Original namespace
PVC_NAME="postgres-pvc"          # Original PVC name
NEW_NAMESPACE="pxbbq"    # New namespace for PVC
SNAPSHOT_NAME="${PVC_NAME}-snapshot"
CLONE_NAME="${PVC_NAME}-clone"
DEPLOYMENT_NAME="postgres"


# Scale down the postgres deployment in the destination namespace
kubectl -n ${NEW_NAMESPACE} scale deployment ${DEPLOYMENT_NAME} --replicas=0

# Clean up resources
kubectl -n ${NEW_NAMESPACE} delete pvc ${PVC_NAME} --ignore-not-found
kubectl -n ${NAMESPACE} delete volumesnapshot ${SNAPSHOT_NAME} --ignore-not-found


# Create a snapshot of the original PVC
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${NAMESPACE}
spec:
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF

# Wait for the snapshot to be ready
while true; do
    STATUS=$(kubectl get volumesnapshot ${SNAPSHOT_NAME} -n ${NAMESPACE} -o jsonpath='{.status.readyToUse}')
    if [ "$STATUS" == "true" ]; then
        break
    fi
    sleep 5
done

# Create a clone using the snapshot
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CLONE_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# Wait for the clone PVC to be bound
while true; do
    STATUS=$(kubectl get pvc ${CLONE_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}')
    if [ "$STATUS" == "Bound" ]; then
        break
    fi
    sleep 5
done

# Set the reclaim policy of the underlying PV to Retain
PV_NAME=$(kubectl get pvc ${CLONE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.volumeName}')
kubectl patch pv ${PV_NAME} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

kubectl delete pvc ${CLONE_NAME} -n ${NAMESPACE}

# Delete the claimref
kubectl patch pv ${PV_NAME} --type='json' -p='[{"op": "remove", "path": "/spec/claimRef"}]'

# Create a new PVC in a different namespace pointing to the existing PV
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NEW_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi  # Match the size of the original PVC
  volumeName: ${PV_NAME}
EOF

# Scale up the postgres deployment in the destination namespace
kubectl -n ${NEW_NAMESPACE} scale deployment ${DEPLOYMENT_NAME} --replicas=1

# Set the pv back to delete
kubectl patch pv ${PV_NAME} -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'


echo "Snapshot, clone, and new PVC created successfully!"

kubectl wait --for=condition=ready pod -l app=postgres -n "$NEW_NAMESPACE" --timeout=60s

#kubectl wait --for=condition=ready pod -l app=pxbbq-web -n "$NEW_NAMESPACE" --timeout=60s

