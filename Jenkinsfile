
pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
  }

  parameters {
    choice(
      name: 'RELEASE_MODE',
      choices: ['STABLE', 'FAULTY_ROLLBACK_TEST'],
      description: 'Choose normal deployment or the rollback demonstration.'
    )
    booleanParam(
      name: 'DEPLOY_TO_KUBERNETES',
      defaultValue: true,
      description: 'Deploy to the configured Kubernetes cluster.'
    )
  }

  environment {
    DOCKERHUB_USERNAME = 'bbhavanasree'
    IMAGE_REPO = 'bbhavanasree/industrial-maintenance-dashboard'
    SMOKE_PORT = '18089'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git log -1 --oneline'
      }
    }

    stage('Validate source') {
      parallel {
        stage('Validate dashboard') {
          steps {
            sh '''
              set -eu
              test -s index.html
              grep -q "Equipment Monitoring Dashboard" index.html
              grep -q "Predictive alerts" index.html
              grep -qi "downtime" index.html
              echo "Dashboard validation passed"
            '''
          }
        }

        stage('Validate Kubernetes manifest') {
          steps {
            sh '''
              set -eu
              test -s deployment.yaml
              grep -q "kind: Deployment" deployment.yaml
              grep -q "kind: Service" deployment.yaml
              grep -q "readinessProbe" deployment.yaml
              echo "Kubernetes manifest validation passed"
            '''
          }
        }
      }
    }

    stage('Build Docker image') {
      steps {
        sh '''
          set -eu
          docker build --pull \
            -t "$IMAGE_REPO:$BUILD_NUMBER" \
            -t "$IMAGE_REPO:latest" .
        '''
      }
    }

    stage('Local HTTP smoke test') {
      steps {
        sh '''
          set -eu

          cleanup() {
            docker rm -f maintenance-smoke >/dev/null 2>&1 || true
          }

          trap cleanup EXIT
          docker rm -f maintenance-smoke >/dev/null 2>&1 || true

          docker run -d \
            --name maintenance-smoke \
            -p "$SMOKE_PORT:80" \
            "$IMAGE_REPO:$BUILD_NUMBER"

          ok=0
          for attempt in $(seq 1 20); do
            if curl --fail --silent \
              "http://127.0.0.1:$SMOKE_PORT/" |
              grep -q "Equipment Monitoring Dashboard"; then
              ok=1
              break
            fi
            sleep 2
          done

          test "$ok" -eq 1
          echo "Local HTTP smoke test passed"
        '''
      }
    }

    stage('Archive artifacts') {
      steps {
        archiveArtifacts(
          artifacts: 'index.html,Dockerfile,Jenkinsfile,deployment.yaml',
          fingerprint: true
        )
      }
    }

    stage('Push image to Docker Hub') {
      steps {
        withCredentials([
          usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'DH_USER',
            passwordVariable: 'DH_TOKEN'
          )
        ]) {
          sh '''
            set +x
            echo "$DH_TOKEN" |
              docker login -u "$DH_USER" --password-stdin

            docker push "$IMAGE_REPO:$BUILD_NUMBER"
            docker push "$IMAGE_REPO:latest"
            docker logout
          '''
        }
      }
    }

    stage('Deploy stable release') {
      when {
        expression {
          return params.DEPLOY_TO_KUBERNETES
        }
      }

      steps {
        withCredentials([
          file(
            credentialsId: 'kubernetes-creds',
            variable: 'KUBECONFIG_FILE'
          )
        ]) {
          sh '''
            set -eu
            export KUBECONFIG="$KUBECONFIG_FILE"

            sed "s|YOUR_DOCKERHUB_USERNAME|$DOCKERHUB_USERNAME|g" \
              deployment.yaml > deployment.rendered.yaml

            kubectl apply -f deployment.rendered.yaml

            kubectl set image \
              deployment/industrial-maintenance-dashboard \
              dashboard="$IMAGE_REPO:$BUILD_NUMBER"

            kubectl rollout status \
              deployment/industrial-maintenance-dashboard \
              --timeout=180s

            kubectl get deployment industrial-maintenance-dashboard
            kubectl get pods -l app=industrial-maintenance-dashboard
            kubectl get service industrial-maintenance-dashboard
          '''
        }
      }
    }

    stage('Fault injection and automatic rollback') {
      when {
        allOf {
          expression {
            return params.RELEASE_MODE == 'FAULTY_ROLLBACK_TEST'
          }
          expression {
            return params.DEPLOY_TO_KUBERNETES
          }
        }
      }

      steps {
        withCredentials([
          file(
            credentialsId: 'kubernetes-creds',
            variable: 'KUBECONFIG_FILE'
          )
        ]) {
          // Build a modified dashboard image for the failure exercise.
          sh '''
            set -eu
            export KUBECONFIG="$KUBECONFIG_FILE"

            sed \
              's/Equipment Monitoring Dashboard/FAULTY RELEASE - SHOULD ROLLBACK/' \
              index.html > faulty-index.html

            docker build \
              --build-arg HTML_FILE=faulty-index.html \
              -t "$IMAGE_REPO:faulty-$BUILD_NUMBER" .
          '''

          withCredentials([
            usernamePassword(
              credentialsId: 'dockerhub-creds',
              usernameVariable: 'DH_USER',
              passwordVariable: 'DH_TOKEN'
            )
          ]) {
            sh '''
              set +x
              echo "$DH_TOKEN" |
                docker login -u "$DH_USER" --password-stdin

              docker push "$IMAGE_REPO:faulty-$BUILD_NUMBER"
              docker logout
            '''
          }

          sh '''
            set -eu
            export KUBECONFIG="$KUBECONFIG_FILE"

            echo "Injecting a bad readiness probe to simulate a failed release"

            kubectl patch deployment industrial-maintenance-dashboard \
              --type='json' \
              -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/intentionally-missing-health-check"}]'

            kubectl set image \
              deployment/industrial-maintenance-dashboard \
              dashboard="$IMAGE_REPO:faulty-$BUILD_NUMBER"

            if kubectl rollout status \
              deployment/industrial-maintenance-dashboard \
              --timeout=45s; then
              echo "ERROR: faulty rollout unexpectedly succeeded."
              exit 1
            else
              echo "Expected failed rollout detected."
            fi

            kubectl describe deployment \
              industrial-maintenance-dashboard || true

            kubectl get pods \
              -l app=industrial-maintenance-dashboard || true

            echo "Rolling back to the previous Deployment revision"

            kubectl rollout undo \
              deployment/industrial-maintenance-dashboard

            kubectl rollout status \
              deployment/industrial-maintenance-dashboard \
              --timeout=180s

            echo "Testing the restored service over HTTP"

            kubectl port-forward \
              service/industrial-maintenance-dashboard \
              18090:80 >/tmp/maintenance-port-forward.log 2>&1 &

            PF_PID=$!
            trap 'kill "$PF_PID" >/dev/null 2>&1 || true' EXIT

            ok=0
            for attempt in $(seq 1 25); do
              if curl --fail --silent \
                http://127.0.0.1:18090/ |
                grep -q "Equipment Monitoring Dashboard"; then
                ok=1
                break
              fi
              sleep 2
            done

            test "$ok" -eq 1

            kubectl get deployment industrial-maintenance-dashboard
            kubectl get pods -l app=industrial-maintenance-dashboard

            echo "Rollback succeeded and the restored dashboard responds to HTTP."
          '''
        }
      }
    }
  }

  post {
    always {
      sh 'docker rm -f maintenance-smoke >/dev/null 2>&1 || true'

      archiveArtifacts(
        artifacts: 'faulty-index.html,deployment.rendered.yaml',
        allowEmptyArchive: true
      )
    }

    success {
      echo 'Pipeline completed successfully.'
    }

    failure {
      echo 'Pipeline failed. Review the stage logs and Kubernetes diagnostics.'
    }
  }
}
