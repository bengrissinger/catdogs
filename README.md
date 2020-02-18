To deploy

1) clone this repo
2) cd to the repo
3) Use Kubectl to find and set context to your cluster you wish to deploy this app to

    kubectl config get-contexts                           # display list of contexts
    
    kubectl config current-context                        # display the current-context
    
    kubectl config use-context my-cluster-name
    
4) Use kubectl to deploy the stack using yaml

