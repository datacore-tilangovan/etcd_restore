#!/bin/bash
YAML_DIR="YAMLs"
DEPLOY_YAML="busybox.yaml"
PVC_YAML="backup-pvc.yaml"
PV_YAML="backup-pv.yaml"
NWP_YAML="networkpolicy.yaml"
DIR=`pwd`
NAMESPACE="$1"
if [ -f "$DIR/$YAML_DIR" ] ; then
    rm "$DIR/$YAML_DIR"
fi
mkdir -p $DIR/$YAML_DIR
####################################################
if [ -z "$1" ]; then
    echo "Error: Please provide a value for namespace"
    echo "script usage: script NAMESPACE_NAME"
    exit 1
fi
########Creating etcd-backup-pv yaml################
echo "\
apiVersion: v1
kind: PersistentVolume
metadata:
  namespace: $NAMESPACE
  name: etcd-backup
spec:
  storageClassName: manual
  # You must also delete the hostpath on the node
  persistentVolumeReclaimPolicy: Retain
  capacity:
    storage: "500Mi"
  accessModes:
    - ReadWriteMany
  hostPath:
    path: "/var/local/backup/"" > $DIR/$YAML_DIR/$PV_YAML
if [ -f "$DIR/$YAML_DIR/$PV_YAML" ];then
        echo "$PV_YAML yaml file created" 
else
        echo "Failed to create etcd-backup yaml" 
        exit 1
fi
#########Creating etcd-backup-pvc yaml##########################
echo "\
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: etcd-backup-pvc
  namespace: $NAMESPACE
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 500Mi
  volumeName: "etcd-backup"" > $DIR/$YAML_DIR/$PVC_YAML
if [ -f "$DIR/$YAML_DIR/$PVC_YAML" ];then
        echo "$PVC_YAML yaml file created" 
else
        echo "Failed to create etcd-backup-pvc yaml" 
        exit 1
fi
##########Creating busybox yaml#####################
echo "\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox
  namespace: mayastor
spec:
  progressDeadlineSeconds: 600
  replicas: 3
  selector:
    matchLabels:
      run: busybox
  template:
    metadata:
      labels:
        run: busybox
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  run: busybox
              namespaces:
                - "mayastor"
              topologyKey: kubernetes.io/hostname
      containers:
      - args:
        - sh
        image: busybox
        imagePullPolicy: Always
        name: busybox
        stdin: true
        tty: true
        volumeMounts:
        - name: pvc1
          mountPath: "/mnt1"
      restartPolicy: Always
      volumes:
      - name: pvc1
        persistentVolumeClaim:
          claimName: etcd-backup-pvc" > $DIR/$YAML_DIR/$DEPLOY_YAML
if [ -f "$DIR/$YAML_DIR/$DEPLOY_YAML" ];then
        echo "$DEPLOY_YAML yaml file created" 
else
        echo "Failed to create etcd-backup-pvc yaml" 
        exit 1
fi
################Network policy yaml################
echo "\
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: etcd-deny-all
  namespace: mayastor
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: etcd
  ingress: []" > $DIR/$YAML_DIR/$NWP_YAML
if [ -f "$DIR/$YAML_DIR/$NWP_YAML" ];then
        echo "$NWP_YAML yaml file created" 
else
        echo "Failed to create $NWP_YAML yaml" 
        exit 1
fi
################Deny traffic to etcd###########

echo "Creating test-etcd-traffic pod" 
kubectl run --image=busybox test-etcd-traffic -n $NAMESPACE -- sleep 3600 
sleep 5s
kubectl exec -it test-etcd-traffic -n $NAMESPACE -- nc -v -w 5  mayastor-etcd 2379 > nc_output_1
test=$(grep -c "open" nc_output_1)
if [ $test -eq 1 ]; then
    echo "traffic to etcd is live, denying incoming traffic to etcd - creating network policy" 
    kubectl apply -f $DIR/$YAML_DIR/$NWP_YAML -n $NAMESPACE 
    kubectl exec -it test-etcd-traffic -n $NAMESPACE -- nc -v -w 5  mayastor-etcd 2379 > nc_output_2
    test1=$(grep -c "timed out" nc_output_2)
        if [ $test1 -eq 1 ]; then
            echo "Network policy applied - All traffic to etcd is denied" 
            echo "Deleting test-etcd-traffic pod" 
            kubectl delete pod test-etcd-traffic -n $NAMESPACE 
	    echo "Deleting network policy"
	    kubectl delete -f $DIR/$YAML_DIR/$NWP_YAML -n $NAMESPACE
            rm nc_output*
        fi
elif [ $test -ne 1 ];then
    echo "traffic to etcd is not live skipping network policy" 
    kubectl delete pod test-etcd-traffic -n $NAMESPACE 
fi

################Taking etcd backup#################
echo "Taking ETCD snapshot" 
etcd=`kubectl get pods -n $NAMESPACE | grep etcd-0 | cut -d " " -f1`
kubectl exec -i $etcd -n $NAMESPACE -- bash -c "etcdctl --endpoints=http://mayastor-etcd-0.mayastor-etcd-headless.mayastor.svc.cluster.local:2379 snapshot save /tmp/snapshot.db" 
kubectl cp -n $NAMESPACE mayastor-etcd-0:/tmp/snapshot.db snapshot.db
if [ -f "$DIR/snapshot.db" ];then
        echo "etcd snapshot created $DIR/snapshot.db" 
else
        echo "Failed to create etcd snapshot" 
        exit 1
fi

################Creating busybox deployments###############
echo "Creating pv/pvc/Deployment for busybox" 
kubectl apply -f $DIR/$YAML_DIR/$PV_YAML -n $NAMESPACE 
if [ $? -ne 0 ];then
        echo "unable to create etcd-backup-pv" ;exit 1 
else
        kubectl apply -f $DIR/$YAML_DIR/$PVC_YAML -n $NAMESPACE 
        if [ $? -ne 0 ];then
                echo "unable to create etcd-backup-pvc" ; exit 1 
        else
        kubectl apply -f $DIR/$YAML_DIR/$DEPLOY_YAML -n $NAMESPACE 
        fi
fi
################copy snapshot to busybox####################
sleep 10s
kubectl -n $NAMESPACE wait pod --for=condition=Ready -l run=busybox 
kubectl get pods -l run=busybox -n $NAMESPACE | cut -d " " -f1 | grep -v "NAME" > busybox_pods
for pods in $(cat busybox_pods);do
        kubectl -n $NAMESPACE cp snapshot.db $pods:/mnt1/snapshot.db
        echo "verifying files in busybox pods" 
        kubectl exec -i $pods -n $NAMESPACE -- ls /mnt1/snapshot.db 
        if [ $? -ne 0 ];then
                echo "unable to copy shapshot file to busybox pod $pods" 
        fi
done
###############unmount pvc from busybox#####################
echo "deleting busybox deployment" 
kubectl -n $NAMESPACE delete deploy busybox
for pods in $(cat busybox_pods);do
        kubectl wait --for=delete pod/$pods --timeout=60s 
done
###############verifying pv and pvc##########################
etcd_pvc=`kubectl get pvc etcd-backup-pvc -n mayastor | cut -d " " -f1 | grep -v "NAME"`
etcd_pv=`kubectl get pv etcd-backup | cut -d " " -f1 | grep -v "NAME"`
echo "#########################PV AND PVC FOR NEW ETCD#########################"
echo "pvc with etcd snapshot available to mount in new etcd \netcd_pvc=$etcd_pvc \netcd_pv=$etcd_pv"
echo "#########################################################################"
################################################################


