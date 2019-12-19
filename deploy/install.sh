# vim: set ts=4 sw=4 tw=0 et :
#!/bin/bash
set -eu -o pipefail

# Installing deps
bash install-deps.sh
export ANSIBLE_HOST_KEY_CHECKING=false

# installing dbs
# Installing all dbs
echo $INVENTORY_PATH
[[ $INVENTORY_PATH == "" ]] && echo -e "ERROR: set environment variable \nexport INVENTORY_PATH=/path/to/ansible/inventory" && exit 100
#########################
#
#       CORE
#
#########################
module=Core
version=2.6.0

echo "downloading artifacts"
artifacts="keycloak_artifacts.zip"

ansible_path=${HOME}/sunbird-devops
for artifact in $artifacts;
do
    wget -N https://sunbirdpublic.blob.core.windows.net/installation/$version/$module/$artifact -P $ansible_path/ansible/
done

# Creating inventory strucure
git checkout -- ../ansible/inventory/env/group_vars/all.yml # This is to make sure always the all.yaml is updated
cp $INVENTORY_PATH/$module/* ../ansible/inventory/env/
# Installing dbs (es, cassandra, postgres)
ansible-playbook -i ../ansible/inventory/env/ ../ansible/provision.yml --skip-tags "postgresql-slave,log-es"
ansible-playbook -i ../ansible/inventory/env/ ../ansible/postgresql-data-update.yml
ansible-playbook -i ../ansible/inventory/env/ ../ansible/es-mapping.yml --extra-vars "indices_name=all ansible_tag=run_all_index_and_mapping"
ansible-playbook -i ../ansible/inventory/env/ ../ansible/cassandra-cassandra-deploy.yml

# Bootstrapping k8s
ansible-playbook -i ../ansible/inventory/env/ ../kubernetes/ansible/bootstrap_minimal.yaml

# Creating private ingress
ansible-playbook -i ../ansible/inventory/env/ ../kubernetes/ansible/deploy_core_service.yml -e "kubeconfig_path=/etc/rancher/k3s/k3s.yaml chart_path=/home/ops/sunbird-devops/kubernetes/helm_charts/core/nginx-private-ingress release_name=nginx-private-ingress role_name=sunbird-deploy"

# Installing API manager
ansible-playbook -i ../ansible/inventory/env/ ../kubernetes/ansible/deploy_core_service.yml -e chart_path=/home/ops/sunbird-devops/kubernetes/helm_charts/core/apimanager -e "release_name=apimanager role_name=sunbird-deploy kong_admin_api_url=http://$(hostname -i)/admin-api" -v

# echo "@@@@@@@@@ Onboard APIs"
ansible-playbook -i ../ansible/inventory/env/ ../ansible/api-manager.yml -e kong_admin_api_url=http://$(hostname -i):12000/admin-api --tags kong-api

# echo "@@@@@@@@@ Onboard Consumers"
## This will generate a player token in /root/jwt_token_player.txt
echo "@@@@@@@@@ Onboard Consumers"
ansible-playbook -v -i ../ansible/inventory/env/ ../ansible/api-manager.yml -e "kong_admin_api_url=http://$(hostname -i):12000/admin-api kubeconfig_path=/etc/rancher/k3s/k3s.yaml" --tags kong-consumer

jwt_token=$(sudo cat /root/jwt_token_player.txt)
# services="adminutil apimanager badger cert content enc learner lms notification player telemetry userorg"
services="adminutils knowledgemw lms apimanager content learner player telemetry nginx-public-ingress"
for service in $services;
do
  echo "@@@@@@@@@@@@@@ Deploying $service @@@@@@@@@@@@@@@@@@"
  ansible-playbook -i ../ansible/inventory/env/ ../kubernetes/ansible/deploy_core_service.yml -e "kubeconfig_path=/etc/rancher/k3s/k3s.yaml chart_path=/home/ops/sunbird-devops/kubernetes/helm_charts/core/${service} release_name=${service} role_name=sunbird-deploy sunbird_api_auth_token=${jwt_token}"
done
# Provisioning keycloak
ansible-playbook -i ../ansible/inventory/env ../ansible/keycloak.yml --tags provision
# Deploying keycloak
ansible-playbook -i ../ansible/inventory/env ../ansible/keycloak.yml --tags deploy -e "artifact_path=keycloak_artifacts.zip deploy_monit=false"
# Bootstrapping keycloak
ansible-playbook -i ../ansible/inventory/env ../ansible/keycloak.yml --tags bootstrap -v

#########################
#
#       KP
#
#########################
# Installing KP
module=KnowledgePlatform
# Checking out specific revision of KP
git clone https://github.com/project-sunbird/sunbird-learning-platform -b release-$version ~/sunbird-learning-platform

# Creating inventory strucure
cp $INVENTORY_PATH/$module/* ../ansible/inventory/env/
cp ~/sunbird-learning-platform/ansible/inventory/env/group_vars/all.yml ../ansible/inventory/env/group_vars/
ansible_path=${HOME}/sunbird-learning-platform

echo "downloading artifacts"
artifacts="lp_artifacts.zip lp_neo4j_artifacts.zip"

for artifact in $artifacts;
do
    wget -N https://sunbirdpublic.blob.core.windows.net/installation/$version/$module/$artifact -P $ansible_path/ansible/
done
# installing unzip
sudo apt install unzip
cd $ansible_path/ansible
find ./ -type f -iname "*.zip" -exec unzip -o {} \;
cd -
# Downloading neo4j
wget -N https://sunbirdpublic.blob.core.windows.net/installation/neo4j-community-3.3.9-unix.tar.gz -P $ansible_path/ansible/artifacts/

ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_cassandra_db_update.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_zookeeper_provision.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_kafka_provision.yml
# Will create all topic
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_kafka_setup.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_learning_neo4j_provision.yml -e "download_neo4j=false neo4j_zip=neo4j-community-3.3.9-unix.tar.gz neo4j_home={{learner_user_home}}/{{neo4j_dir}}/neo4j-community-3.3.9"
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_learning_neo4j_deploy.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_start_neo4j.yml -e "neo4j_home={{learner_user_home}}/{{neo4j_dir}}/neo4j-community-3.3.9"
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/es_composite_search_cluster_setup.yml -v
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_definition_update.yml -e "neo4j_home={{learner_user_home}}/{{neo4j_dir}}/neo4j-community-3.3.9"
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_redis_provision.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_learning_provision.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_learning_deploy.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_search_provision.yml
ansible-playbook -i ../ansible/inventory/env ${ansible_path}/ansible/lp_search_deploy.yml
