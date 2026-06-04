#!/usr/bin/env groovy
// =============================================================================
// Cafe App Website — Jenkins CI/CD for Kubernetes agents
// Builds static site using Python generator, packages with Nginx,
// pushes to Docker Hub
// =============================================================================

pipeline {
    agent {
        kubernetes {
            label 'cafeapp-kaniko-agent'
            defaultContainer 'tools'
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  namespace: ns-jenkins
spec:
  serviceAccountName: jenkins
  containers:
    - name: tools
      image: python:3.12-slim
      command: ['sh', '-c', 'cat']
      tty: true
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.24.0-debug
      command: ['/busybox/sh', '-c', 'cat']
      tty: true
    - name: trivy
      image: aquasec/trivy:0.52.2
      command: ['sh', '-c', 'cat']
      tty: true
'''
        }
    }

    parameters {
        string(name: 'DOCKERHUB_ORG', defaultValue: 'mokadir', description: 'Docker Hub organisation/username')
        string(name: 'IMAGE_TAG', defaultValue: '${BUILD_NUMBER}', description: 'Image tag. Leave empty to auto-generate from Jenkins build number')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch to build from')
        choice(name: 'BUILD_ENV', choices: ['staging', 'production'], description: 'Target environment')
        booleanParam(name: 'RUN_CONTAINER_SCAN', defaultValue: true, description: 'Run Trivy image scan after build')
        booleanParam(name: 'PUSH_IMAGE', defaultValue: true, description: 'Push image to Docker Hub')
        booleanParam(name: 'PUSH_LATEST_TAG', defaultValue: true, description: 'Also push :latest on main/production')
        string(name: 'TRIVY_SEVERITY', defaultValue: 'HIGH,CRITICAL', description: 'Trivy severity threshold')
        booleanParam(name: 'FAIL_ON_VULN', defaultValue: false, description: 'Fail build on vulnerabilities')
        string(name: 'SLACK_CHANNEL', defaultValue: '', description: 'Optional Slack channel for notifications')
        choice(name: 'BUILD_PLATFORM', choices: ['linux/amd64', 'linux/arm', 'linux/arm64'], description: 'Target platform/architecture for the Docker image')
    }

    environment {
        DOCKERHUB_ORG = "${params.DOCKERHUB_ORG}"
        BUILD_ENV = "${params.BUILD_ENV}"
        TRIVY_SEVERITY = "${params.TRIVY_SEVERITY}"
        IMAGE_TAG = "${params.IMAGE_TAG}"
        BUILD_PLATFORM = "${params.BUILD_PLATFORM}"
        SHORT_SHA = ''
        APP_NAME = 'cafeapp-arm'
    }

    options {
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
        timestamps()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: "*/${params.GIT_BRANCH}"]],
                    extensions: [[$class: 'CleanBeforeCheckout']],
                    userRemoteConfigs: scm.userRemoteConfigs
                ])
            }
        }

        stage('Resolve Metadata') {
            steps {
                container('tools') {
                    sh 'apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1'
                }
                script {
                    sh 'git config --global --add safe.directory ${WORKSPACE}'
                    env.SHORT_SHA = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    def rawTag = params.IMAGE_TAG?.trim()
                    def safeBranch = params.GIT_BRANCH.replaceAll('[^a-zA-Z0-9._-]', '-').toLowerCase()
                    env.IMAGE_TAG = rawTag ? rawTag : "${safeBranch}-${env.SHORT_SHA}"
                    echo "Organisation : ${env.DOCKERHUB_ORG}"
                    echo "Image Tag    : ${env.IMAGE_TAG}"
                    echo "Branch       : ${params.GIT_BRANCH}"
                    echo "Environment  : ${env.BUILD_ENV}"
                    echo "Platform     : ${params.BUILD_PLATFORM}"
                    echo "Commit SHA   : ${env.SHORT_SHA}"
                }
            }
        }

        stage('Preflight') {
            steps {
                container('tools') {
                    sh '''
                        set -eux
                        python --version
                        pip --version
                    '''
                }
                container('kaniko') {
                    sh '/kaniko/executor version'
                }
                container('trivy') {
                    sh 'trivy --version'
                }
            }
        }

        stage('Generate Static Site') {
            steps {
                container('tools') {
                    sh '''
                        set -eux
                        python generate.py
                        ls -la index.html
                        echo "Static site generated successfully"
                    '''
                }
            }
        }

        stage('Prepare Registry Auth') {
            when { expression { params.PUSH_IMAGE } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-cred', usernameVariable: 'DOCKERHUB_USERNAME', passwordVariable: 'DOCKERHUB_PASSWORD')]) {
                    container('kaniko') {
                        sh '''
                            set -eu
                            mkdir -p /kaniko/.docker
                            cat > /kaniko/.docker/config.json <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "username": "${DOCKERHUB_USERNAME}",
      "password": "${DOCKERHUB_PASSWORD}"
    }
  }
}
EOF
                        '''
                    }
                }
            }
        }

        stage('Build And Push Docker Image') {
            steps {
                script {
                    def imageName = "${env.DOCKERHUB_ORG}/${env.APP_NAME}:${env.IMAGE_TAG}"
                    def tarPath = "${env.WORKSPACE}/${env.APP_NAME}-${env.IMAGE_TAG}.tar"

                    try {
                        def kanikoCommand = "/kaniko/executor --context ${env.WORKSPACE} --dockerfile ${env.WORKSPACE}/Dockerfile --destination ${imageName} --multi-platform --platform=${env.BUILD_PLATFORM}"

                        if (params.PUSH_IMAGE && params.PUSH_LATEST_TAG) {
                            def latestTag = "${env.DOCKERHUB_ORG}/${env.APP_NAME}:latest"
                            kanikoCommand += " --destination ${latestTag}"
                        }

                        kanikoCommand += " --label org.opencontainers.image.revision=${env.SHORT_SHA}"
                        kanikoCommand += " --label org.opencontainers.image.source=https://github.com/${env.DOCKERHUB_ORG}/${env.APP_NAME}-website"
                        kanikoCommand += " --label org.opencontainers.image.version=${env.IMAGE_TAG}"
                        kanikoCommand += " --label com.${env.APP_NAME}.environment=${env.BUILD_ENV}"
                        kanikoCommand += " --snapshot-mode=redo --use-new-run --cache=false"

                        if (!params.PUSH_IMAGE) {
                            kanikoCommand += ' --no-push'
                        }

                        if (params.RUN_CONTAINER_SCAN && !params.PUSH_IMAGE) {
                            kanikoCommand += " --tar-path ${tarPath}"
                        }

                        container('kaniko') {
                            sh """
                                set -eux
                                export GODEBUG=http2client=0
                                retry_count=0
                                until [ "\$retry_count" -ge 3 ]; do
                                    echo "Running Kaniko push attempt \$((retry_count + 1))"
                                    ${kanikoCommand} && break
                                    rc=\$?
                                    echo "Kaniko push failed with exit code \$rc"
                                    retry_count=\$((retry_count + 1))
                                    if [ "\$retry_count" -ge 3 ]; then
                                        exit \$rc
                                    fi
                                    echo "Retrying Kaniko push in 5s..."
                                    sleep 5
                                done
                            """
                        }

                        if (params.RUN_CONTAINER_SCAN) {
                            container('trivy') {
                                if (params.PUSH_IMAGE) {
                                    sh """
                                        trivy image \
                                            --exit-code ${params.FAIL_ON_VULN ? '1' : '0'} \
                                            --severity ${env.TRIVY_SEVERITY} \
                                            --format table \
                                            --output trivy-image-report.txt \
                                            ${imageName} || true
                                    """
                                } else {
                                    sh """
                                        trivy image \
                                            --input ${tarPath} \
                                            --exit-code ${params.FAIL_ON_VULN ? '1' : '0'} \
                                            --severity ${env.TRIVY_SEVERITY} \
                                            --format table \
                                            --output trivy-image-report.txt \
                                            || true
                                    """
                                }
                            }
                            archiveArtifacts artifacts: 'trivy-image-report.txt', allowEmptyArchive: true
                        }

                    } catch (err) {
                        echo "ERROR building image: ${err.message}"
                        currentBuild.result = 'UNSTABLE'
                        error("Image build failed: ${err.message}")
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (params.SLACK_CHANNEL?.trim()) {
                    try {
                        def status = currentBuild.currentResult
                        def color = status == 'SUCCESS' ? 'good' : (status == 'UNSTABLE' ? 'warning' : 'danger')
                        slackSend(
                            channel: params.SLACK_CHANNEL,
                            color: color,
                            message: "Cafe App CI/CD ${status} | Branch=${params.GIT_BRANCH} | Tag=${env.IMAGE_TAG} | Env=${env.BUILD_ENV} | Build=${env.BUILD_URL}",
                            tokenCredentialId: 'slack-bot-token'
                        )
                    } catch (ignored) {
                        echo 'Slack notification skipped'
                    }
                }
                cleanWs()
            }
        }

        failure {
            script {
                echo "Build failed. Check logs for details."
            }
        }

        success {
            script {
                def imageName = "${env.DOCKERHUB_ORG}/${env.APP_NAME}:${env.IMAGE_TAG}"
                echo "Build successful!"
                echo "Image: ${imageName}"
            }
        }
    }
}
