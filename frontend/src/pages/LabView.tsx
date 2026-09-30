import { useState, useEffect } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import axios from 'axios';
import Terminal from '../components/Terminal';

interface Lab {
  id: string;
  template: string;
  status: string;
  nodes?: string[];
}

export default function LabView() {
  const { id } = useParams();
  const navigate = useNavigate();
  const [lab, setLab] = useState<Lab | null>(null);
  const [activeNode, setActiveNode] = useState<string | null>(null);
  const [result, setResult] = useState<any>(null);

  const token = localStorage.getItem('token');
  const config = { headers: { Authorization: `Bearer ${token}` } };

  useEffect(() => {
    let interval: any;
    const fetchLab = async () => {
      try {
        const res = await axios.get(`/api/labs/${id}`, config);
        setLab(res.data);
      } catch (e) {
        console.error(e);
      }
    };

    fetchLab();
    interval = setInterval(fetchLab, 5000);
    return () => clearInterval(interval);
  }, [id]);

  const handleAction = async (action: string) => {
    try {
      const res = await axios.post(`/api/labs/${id}/${action}`, {}, config);
      if (action === 'submit') {
        setResult(res.data);
      } else if (action === 'finish') {
        navigate('/labs');
      }
    } catch (e) {
      alert(`Action ${action} failed`);
    }
  };

  if (!lab) return <div>Loading...</div>;

  const wsUrl = activeNode 
    ? `ws://${window.location.hostname}:4000/ws/console?labId=${id}&netns=${activeNode}&isRouter=${activeNode.startsWith('r')}&token=${token}`
    : '';

  const isRequesting = lab.status === 'requesting' || lab.status === 'resetting';
  const nodes = lab.nodes || ['r1', 'r2', 'h1', 'h2']; // Fallback if backend doesn't send

  return (
    <div className="layout">
      <div className="panel-left">
        <h3>{lab.template.toUpperCase()}</h3>
        <p>Topology Description</p>
        <h4>Nodes</h4>
        {nodes.map(n => (
          <button 
            key={n} 
            className="btn" 
            style={{ display: 'block', width: '100%', marginBottom: '10px', background: activeNode === n ? '#0056b3' : '#007bff' }}
            onClick={() => setActiveNode(n)}
            disabled={lab.status !== 'ready'}
          >
            {n} {n.startsWith('r') ? '(Router)' : '(Host)'}
          </button>
        ))}
      </div>
      
      <div className="panel-main">
        {isRequesting && <div style={{ color: 'white', padding: '20px' }}>Loading... (Spinning up lab)</div>}
        {!isRequesting && !activeNode && <div style={{ color: 'white', padding: '20px' }}>Select a node to open terminal</div>}
        {!isRequesting && activeNode && <Terminal wsUrl={wsUrl} key={activeNode} />}
      </div>

      <div className="panel-right">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <h3>Status</h3>
            <span className={`badge badge-${lab.status}`}>{lab.status}</span>
        </div>
        
        <hr />
        <h4>Instructions</h4>
        <p>Complete the {lab.template} configuration.</p>
        
        <hr />
        <h4>Actions</h4>
        <button className="btn" onClick={() => handleAction('reset')} disabled={lab.status !== 'ready'}>Reset Lab</button>
        <button className="btn" onClick={() => handleAction('submit')} disabled={lab.status !== 'ready'}>Submit Results</button>
        <button className="btn btn-danger" onClick={() => handleAction('finish')}>Finish Lab</button>
      </div>

      {result && (
        <div className="modal">
          <div className="modal-content">
            <h3>Submission Result</h3>
            <p>Score: {result.score}</p>
            <ul>
                {(result.checks || []).map((c: any, i: number) => (
                    <li key={i}>{c.name}: {c.pass ? 'PASS' : 'FAIL'}</li>
                ))}
            </ul>
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: '20px' }}>
                <button className="btn" onClick={() => setResult(null)}>Close</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
