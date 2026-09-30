import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';

interface Lab {
  id: string;
  template: string;
  status: string;
  createdTime: string;
}

export default function LabList() {
  const [labs, setLabs] = useState<Lab[]>([]);
  const [showModal, setShowModal] = useState(false);
  const [selectedTemplate, setSelectedTemplate] = useState('ospf');
  const navigate = useNavigate();

  const token = localStorage.getItem('token');
  const config = { headers: { Authorization: `Bearer ${token}` } };

  const fetchLabs = async () => {
    try {
      const res = await axios.get('/api/labs', config);
      setLabs(res.data);
    } catch (e) {
      if (axios.isAxiosError(e) && e.response?.status === 401) {
        navigate('/login');
      }
    }
  };

  useEffect(() => {
    fetchLabs();
  }, []);

  const handleCreate = async () => {
    try {
      const res = await axios.post('/api/labs', { template: selectedTemplate }, config);
      navigate(`/labs/${res.data.id}`);
    } catch (e) {
      alert('Failed to create lab');
    }
  };

  const hasActiveLab = labs.some(l => l.status === 'active' || l.status === 'requesting');

  return (
    <div className="container">
      <h2>My Labs</h2>
      <button className="btn" onClick={() => setShowModal(true)} disabled={hasActiveLab}>
        New Lab
      </button>

      <table>
        <thead>
          <tr>
            <th>Template</th>
            <th>Status</th>
            <th>Created Time</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {labs.map(lab => (
            <tr key={lab.id}>
              <td>{lab.template}</td>
              <td><span className={`badge badge-${lab.status}`}>{lab.status}</span></td>
              <td>{new Date(lab.createdTime).toLocaleString()}</td>
              <td>
                <button className="btn" onClick={() => navigate(`/labs/${lab.id}`)}>Open</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      {showModal && (
        <div className="modal">
          <div className="modal-content">
            <h3>Select Template</h3>
            <div className="form-group">
              <select className="form-control" value={selectedTemplate} onChange={e => setSelectedTemplate(e.target.value)}>
                <option value="ospf">OSPF Routing</option>
                <option value="static-routing">Static Routing</option>
                <option value="vlan">VLANs</option>
              </select>
            </div>
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: '20px' }}>
              <button className="btn" onClick={() => setShowModal(false)} style={{ background: '#6c757d' }}>Cancel</button>
              <button className="btn" onClick={handleCreate}>Create</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
