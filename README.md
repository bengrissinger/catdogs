To deploy

1) clone this repo
2) cd to the repo
3) Use Kubectl to find and set context to your cluster you wish to deploy this app to

    kubectl config get-contexts                           # display list of contexts
    
    kubectl config current-context                        # display the current-context
    
    kubectl config use-context my-cluster-name
    
4) Create votes namespace

    kubectl create ns votes
    
5) Use kubectl to deploy the stack using kube-deployment.yaml

    kubectl create -f kube-deployment.yaml -n votes
    
Have fun voting !!!


To tear down deployment 

    kubectl delete -f kube-deployment.yaml -n votes

