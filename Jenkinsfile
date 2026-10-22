
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    parameters {
        booleanParam(
            name: 'PUSH_TO_DOCKERHUB',
            defaultValue: true,
            description: 'Push the image to Docker Hub'
        )
        booleanParam(
            name: 'DEPLOY_TO_KUBERNETES',
            defaultValue: false,
            description: 'Deploy to Kubernetes using kubernetes-creds'
        )
        choice(
            name: 'RELEASE_MODE',
            choices: ['STABLE', 'FAULTY_ROLLBACK_TEST'],
            description: 'Choose a normal deployment or test automatic rollback'
        )
    }

    environment {
        DOCKERHUB_REPO = 'bbhavanasree/industrial-maintenance-dashboard'
        DEPLOYMENT_NAME = 'industrial-maintenance-dashboard'
        IMAGE_TAG = "${BUILD_NUMBER}"
        SMOKE_CONTAINER = "ipm-smoke-${BUILD_NUMBER}"
    }

    stages {
        stage('Validate source') {
            steps {
                echo 'Checking project files...'
                bat '''
                    @echo off
                    if not exist index.html (
                        echo ERROR: index.html not found
                        exit /b 1
                    )
                    if not exist Dockerfile (
                        echo ERROR: Dockerfile not found
                        exit /b 1
                    )
                    if not exist deployment.yaml (
                        echo ERROR: deployment.yaml not found
                        exit /b 1
                    )
                    if not exist Jenkinsfile (
                        echo ERROR: Jenkinsfile not found
                        exit /b 1
                    )
                    echo All required files are present.
                '''
            }
        }

        stage('Check Docker') {
            steps {
                bat '''
                    @echo off
                    docker --version
                    if errorlevel 1 exit /b 1
                    docker info
                    if errorlevel 1 (
                        echo ERROR: Jenkins cannot access Docker.
                        exit /b 1
                    )
                '''
            }
        }

        stage('Validate Kubernetes manifest') {
            steps {
                bat '''
                    @echo off
                    findstr /I /C:"kind: Deployment" deployment.yaml
                    if errorlevel 1 (
                        echo ERROR: Deployment not found in deployment.yaml
                        exit /b 1
                    )
                    findstr /I /C:"kind: Service" deployment.yaml
                    if errorlevel 1 (
                        echo ERROR: Service not found in deployment.yaml
                        exit /b 1
                    )
                    echo Kubernetes manifest basic checks passed.
                '''
            }
        }

        stage('Build Docker image') {
            steps {
                bat '''
                    @echo off
                    docker build --pull ^
                      -t "%DOCKERHUB_REPO%:%IMAGE_TAG%" ^
                      -t "%DOCKERHUB_REPO%:latest" .
                    if errorlevel 1 exit /b 1
                    docker image inspect "%DOCKERHUB_REPO%:%IMAGE_TAG%"
                    if errorlevel 1 exit /b 1
                '''
            }
        }

        stage('Local HTTP smoke test') {
            steps {
                bat '''
                    @echo off
                    docker rm -f "%SMOKE_CONTAINER%" 2>NUL
                    docker run -d --name "%SMOKE_CONTAINER%" -p 127.0.0.1:18080:80 "%DOCKERHUB_REPO%:%IMAGE_TAG%"
                    if errorlevel 1 exit /b 1
                '''

                powershell(
                    label: 'Wait for dashboard HTTP response',
                    script: '''
                        $ready = $false

                        for ($i = 0; $i -lt 20; $i++) {
                            try {
                                $response = Invoke-WebRequest `
                                    -Uri 'http://127.0.0.1:18080/' `
                                    -UseBasicParsing `
                                    -TimeoutSec 3

                                if ($response.StatusCode -eq 200) {
                                    $ready = $true
                                    break
                                }
                            }
                            catch {
                                Start-Sleep -Seconds 2
                            }
                        }

                        if (-not $ready) {
                            docker logs $env:SMOKE_CONTAINER
                            throw 'Dashboard HTTP smoke test failed.'
                        }

                        Write-Host 'Dashboard returned HTTP 200.'
                    '''
                )
            }
            post {
                always {
                    bat '''
                        @echo off
                        docker rm -f "%SMOKE_CONTAINER%" 2>NUL
                        exit /b 0
                    '''
                }
            }
        }

        stage('Archive artifacts') {
            steps {
                archiveArtifacts(
                    artifacts: 'index.html,Dockerfile,Jenkinsfile,deployment.yaml',
                    allowEmptyArchive: false
                )
            }
        }

        stage('Push image to Docker Hub') {
            when {
                expression { params.PUSH_TO_DOCKERHUB }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'dockerhub-creds',
                        usernameVariable: 'DOCKERHUB_USER',
                        passwordVariable: 'DOCKERHUB_TOKEN'
                    )
                ]) {
                    bat '''
                        @echo off
                        powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:DOCKERHUB_TOKEN | docker login --username $env:DOCKERHUB_USER --password-stdin"
                        if errorlevel 1 exit /b 1

                        docker push "%DOCKERHUB_REPO%:%IMAGE_TAG%"
                        if errorlevel 1 exit /b 1

                        docker push "%DOCKERHUB_REPO%:latest"
                        if errorlevel 1 exit /b 1

                        docker logout
                    '''
                }
            }
        }

        stage('Deploy stable release') {
            when {
                allOf {
                    expression { params.DEPLOY_TO_KUBERNETES }
                    expression { params.RELEASE_MODE == 'STABLE' }
                }
            }
            steps {
                script {
                    withCredentials([
                        file(
                            credentialsId: 'kubernetes-creds',
                            variable: 'KUBECONFIG_FILE'
                        )
                    ]) {
                        bat '''
                            @echo off
                            set "KUBECONFIG=%KUBECONFIG_FILE%"

                            kubectl config current-context
                            if errorlevel 1 exit /b 1

                            powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = 'deployment.yaml'; $s = [IO.File]::ReadAllText($p); $s = $s.Replace('YOUR_DOCKERHUB_USERNAME/industrial-maintenance-dashboard:latest', ($env:DOCKERHUB_REPO + ':' + $env:IMAGE_TAG)); [IO.File]::WriteAllText($p, $s)"
                            if errorlevel 1 exit /b 1

                            kubectl apply -f deployment.yaml
                            if errorlevel 1 exit /b 1

                            kubectl rollout status deployment/%DEPLOYMENT_NAME% --timeout=180s
                            if errorlevel 1 exit /b 1

                            kubectl get deployment %DEPLOYMENT_NAME%
                            kubectl get service
                        '''
                    }
                }
            }
        }

        stage('Fault injection and automatic rollback') {
            when {
                allOf {
                    expression { params.DEPLOY_TO_KUBERNETES }
                    expression { params.RELEASE_MODE == 'FAULTY_ROLLBACK_TEST' }
                }
            }
            steps {
                script {
                    withCredentials([
                        file(
                            credentialsId: 'kubernetes-creds',
                            variable: 'KUBECONFIG_FILE'
                        )
                    ]) {
                        bat '''
                            @echo off
                            set "KUBECONFIG=%KUBECONFIG_FILE%"

                            powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = 'deployment.yaml'; $s = [IO.File]::ReadAllText($p); $s = $s.Replace('YOUR_DOCKERHUB_USERNAME/industrial-maintenance-dashboard:latest', ($env:DOCKERHUB_REPO + ':' + $env:IMAGE_TAG)); [IO.File]::WriteAllText($p, $s)"
                            if errorlevel 1 exit /b 1

                            kubectl apply -f deployment.yaml
                            if errorlevel 1 exit /b 1

                            kubectl rollout status deployment/%DEPLOYMENT_NAME% --timeout=180s
                            if errorlevel 1 exit /b 1

                            echo Injecting a deliberately invalid image to test rollback.
                            kubectl set image deployment/%DEPLOYMENT_NAME% *=invalid-image-for-rollback-test:does-not-exist
                            if errorlevel 1 exit /b 1

                            kubectl rollout status deployment/%DEPLOYMENT_NAME% --timeout=60s
                            if not errorlevel 1 (
                                echo WARNING: Faulty rollout unexpectedly succeeded.
                                exit /b 1
                            )

                            echo Fault detected. Rolling back to the previous release.
                            kubectl rollout undo deployment/%DEPLOYMENT_NAME%
                            if errorlevel 1 exit /b 1

                            kubectl rollout status deployment/%DEPLOYMENT_NAME% --timeout=180s
                            if errorlevel 1 exit /b 1

                            echo Rollback completed successfully.
                            kubectl get deployment %DEPLOYMENT_NAME%
                        '''
                    }
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline completed successfully.'
            echo 'Dashboard image: Docker Hub repository and build-number tag.'
        }
        failure {
            echo 'Pipeline failed. Review the first failing stage in Console Output.'
        }
        always {
            echo 'Pipeline execution finished.'
        }
    }
}
