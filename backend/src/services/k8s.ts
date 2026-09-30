import * as k8s from '@kubernetes/client-node';
import stream from 'stream';

let kc: k8s.KubeConfig;
let k8sApi: k8s.CoreV1Api;
let k8sNetApi: k8s.NetworkingV1Api;
let k8sExec: k8s.Exec;

export function initK8sClient(): void {
  kc = new k8s.KubeConfig();
  const kubeconfigPath = process.env.KUBECONFIG || '/root/.kube/config';
  kc.loadFromFile(kubeconfigPath);
  k8sApi    = kc.makeApiClient(k8s.CoreV1Api);
  k8sNetApi = kc.makeApiClient(k8s.NetworkingV1Api);
  k8sExec   = new k8s.Exec(kc);
}

/** Returns the initialised KubeConfig (used by ws.ts Exec). */
export function getKubeConfig(): k8s.KubeConfig {
  if (!kc) throw new Error('K8s client not initialised — call initK8sClient() first');
  return kc;
}

export async function createLabNamespace(labId: string, template: string): Promise<string> {
  const namespace = `lab-${labId.slice(0, 8)}`;

  await k8sApi.createNamespace({
    metadata: {
      name: namespace,
      labels: {
        'managed-by': 'netlab',
        'lab-id': labId,
      },
    },
  });

  await k8sApi.createNamespacedResourceQuota(namespace, {
    metadata: { name: 'lab-quota' },
    spec: {
      hard: {
        pods: '1',
        'requests.memory': '256Mi',
        'limits.memory': '256Mi',
      },
    },
  });

  await k8sNetApi.createNamespacedNetworkPolicy(namespace, {
    metadata: { name: 'default-deny-all' },
    spec: {
      podSelector: {},
      policyTypes: ['Ingress', 'Egress'],
    },
  });

  return namespace;
}

export async function createLabPod(labId: string, namespace: string, template: string, userId: string): Promise<string> {
  const podName = `lab-pod-${labId.slice(0, 8)}`;

  await k8sApi.createNamespacedPod(namespace, {
    metadata: {
      name: podName,
      labels: {
        app: 'lab-node',
        'lab-id': labId,
        'user-id': userId,
      },
    },
    spec: {
      containers: [
        {
          name: 'lab-node',
          image: 'netlab/lab-node:latest',
          imagePullPolicy: 'Never',
          env: [
            { name: 'TOPO_TEMPLATE', value: `/templates/${template}.json` },
            { name: 'LAB_ID',        value: labId },
            // TOPO_JSON is the canonical path used by wait-frr.sh readiness probe
            { name: 'TOPO_JSON',     value: '/lab/current-topo.json' },
          ],
          volumeMounts: [
            { name: 'lab-templates', mountPath: '/templates' },
          ],
          securityContext: {
            privileged: false,
            capabilities: { add: ['NET_ADMIN', 'NET_RAW', 'SYS_ADMIN'] },
            allowPrivilegeEscalation: true,
          },
          readinessProbe: {
            exec: { command: ['/usr/local/bin/wait-frr.sh'] },
            initialDelaySeconds: 10,
            periodSeconds: 5,
            failureThreshold: 24,
          },
          resources: {
            requests: { memory: '128Mi', cpu: '100m' },
            limits: { memory: '256Mi', cpu: '1000m' },
          },
        },
      ],
      volumes: [
        {
          name: 'lab-templates',
          hostPath: { path: '/lab-templates' },
        },
      ],
      restartPolicy: 'Never',
    },
  });

  return podName;
}

export async function waitForPodReady(namespace: string, podName: string, timeoutMs: number = 120000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const res = await k8sApi.readNamespacedPod(podName, namespace);
    const conditions = res.body.status?.conditions;
    if (conditions) {
      const readyCondition = conditions.find((c) => c.type === 'Ready');
      if (readyCondition && readyCondition.status === 'True') {
        return;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  throw new Error(`Timeout waiting for pod ${podName} in namespace ${namespace} to become Ready`);
}

export async function destroyLab(namespace: string): Promise<void> {
  try {
    await k8sApi.deleteNamespace(namespace);
  } catch (error: any) {
    if (error.statusCode !== 404) {
      throw error;
    }
  }
}

export async function getPodStatus(namespace: string, podName: string): Promise<string> {
  try {
    const res = await k8sApi.readNamespacedPod(podName, namespace);
    return res.body.status?.phase || 'Unknown';
  } catch (error: any) {
    if (error.statusCode === 404) {
      return 'NotFound';
    }
    throw error;
  }
}

export async function execInPodNetns(namespace: string, podName: string, netns: string, isRouter: boolean): Promise<any> {
  // For routers: use vtysh -N <name> to connect to the FRR pathspace
  // For hosts: use ip netns exec <name> bash for a shell
  const command = isRouter
    ? ['vtysh', '-N', netns]
    : ['ip', 'netns', 'exec', netns, 'bash'];

  const stdout = new stream.PassThrough();
  const stderr = new stream.PassThrough();
  const stdin = new stream.PassThrough();
  
  const conn = await k8sExec.exec(namespace, podName, 'lab-node', command, stdout, stderr, stdin, true, (status) => {
    // Process status if needed
  });

  return { conn, stdin, stdout, stderr };
}
