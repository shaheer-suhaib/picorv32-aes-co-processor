import { useState, useRef } from 'react'
import './App.css'

function App() {
  const [file, setFile] = useState(null)
  const [preview, setPreview] = useState(null)
  const [txStatus, setTxStatus] = useState('idle') // idle, working, success, error
  const [rxStatus, setRxStatus] = useState('idle')
  const [logs, setLogs] = useState([])
  const fileInputRef = useRef(null)

  const addLog = (msg, type = 'info') => {
    const time = new Date().toLocaleTimeString()
    setLogs(prev => [...prev, { time, msg, type }])
  }

  const handleFileChange = (e) => {
    const selected = e.target.files[0]
    if (!selected) return

    if (selected.name.split('.').pop() !== 'bmp') {
      addLog(`Invalid file type: ${selected.name}. Please upload a .bmp file.`, 'error')
      return
    }

    setFile(selected)
    const objectUrl = URL.createObjectURL(selected)
    setPreview(objectUrl)
    addLog(`Loaded image: ${selected.name} (${selected.size} bytes)`, 'success')
    setTxStatus('idle')
    setRxStatus('idle')
  }

  const handleUploadClick = () => {
    fileInputRef.current.click()
  }

  // MOCK: Replace this with actual API call to your python backend
  const runTxScript = async () => {
    if (!file) return
    setTxStatus('working')
    addLog(`Initiating prepare_tx_sd.py for ${file.name}...`, 'info')
    
    // Simulate python script execution time
    setTimeout(() => {
      // In reality, you'd use fetch() to send the file to a Python backend endpoint
      /*
        const formData = new FormData();
        formData.append('image', file);
        await fetch('http://localhost:5000/prepare-tx', { method: 'POST', body: formData })
      */
      addLog('Writing raw sectors to TX SD card...', 'info')
      setTimeout(() => {
        setTxStatus('success')
        addLog('Successfully written to Transmitter SD Card. Ready for hardware transfer.', 'success')
      }, 1500)
    }, 1000)
  }

  // MOCK: Replace this with actual API call to your python backend
  const runRxScript = async () => {
    setRxStatus('working')
    addLog('Initiating read_rx_sd.py on Receiver SD card...', 'info')
    
    // Simulate python script execution time
    setTimeout(() => {
      /*
        const response = await fetch('http://localhost:5000/read-rx')
        const data = await response.json()
      */
      addLog('Reading received cipher blocks from SD card...', 'info')
      setTimeout(() => {
        setRxStatus('success')
        addLog('Image successfully verified and reconstructed from RX SD card!', 'success')
      }, 2000)
    }, 1000)
  }

  return (
    <div className="app-container">
      <header className="header">
        <h1>AES Hardware Transfer UI</h1>
        <p>Interface for prepare_tx_sd.py and read_rx_sd.py</p>
      </header>

      <div className="dashboard">
        
        {/* Transmitter Panel */}
        <div className="glass-panel">
          <h2 className="panel-title">📡 Transmitter (TX)</h2>
          
          <div className="upload-area" onClick={handleUploadClick}>
            <input 
              type="file" 
              accept=".bmp" 
              className="file-input" 
              ref={fileInputRef}
              onChange={handleFileChange}
            />
            {preview ? (
              <div className="image-preview">
                <img src={preview} alt="Upload preview" />
                <p style={{marginTop: '0.5rem', color: 'var(--text-muted)'}}>{file.name}</p>
              </div>
            ) : (
              <>
                <div className="upload-icon">📁</div>
                <h3>Select 32x32 BMP Image</h3>
                <p style={{color: 'var(--text-muted)', fontSize: '0.9rem', marginTop: '0.5rem'}}>Click or drag and drop</p>
              </>
            )}
          </div>

          <button 
            className="btn btn-primary" 
            onClick={runTxScript}
            disabled={!file || txStatus === 'working'}
          >
            {txStatus === 'working' ? <div className="spinner"></div> : '▶ Run prepare_tx_sd.py'}
          </button>

          <div className="status-badge">
            <div className={`status-dot ${txStatus}`}></div>
            <span>
              {txStatus === 'idle' && 'Waiting for file'}
              {txStatus === 'working' && 'Writing to SD...'}
              {txStatus === 'success' && 'Ready to Transmit'}
              {txStatus === 'error' && 'Failed to write'}
            </span>
          </div>
        </div>

        {/* Receiver Panel */}
        <div className="glass-panel">
          <h2 className="panel-title">🎯 Receiver (RX)</h2>
          
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
            <p style={{ color: 'var(--text-muted)', marginBottom: '2rem', textAlign: 'center' }}>
              Press BTNC on the TX FPGA to start hardware transfer. Once the transfer is complete, run this script to verify the received image on the RX SD card.
            </p>
            
            <button 
              className="btn btn-secondary" 
              onClick={runRxScript}
              disabled={rxStatus === 'working' || txStatus !== 'success'}
            >
              {rxStatus === 'working' ? <div className="spinner"></div> : '🔍 Run read_rx_sd.py'}
            </button>
          </div>

          <div className="status-badge">
            <div className={`status-dot ${rxStatus}`}></div>
            <span>
              {rxStatus === 'idle' && 'Waiting for hardware transfer'}
              {rxStatus === 'working' && 'Reading & Verifying...'}
              {rxStatus === 'success' && 'Verification Passed'}
              {rxStatus === 'error' && 'Verification Failed'}
            </span>
          </div>
        </div>

      </div>

      {/* Global Log Panel */}
      <div className="glass-panel" style={{ padding: '1.5rem' }}>
        <h3 style={{ marginBottom: '1rem', display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          📝 System Logs
        </h3>
        <div className="status-log">
          {logs.length === 0 && <span style={{opacity: 0.5}}>&gt; Awaiting commands...</span>}
          {logs.map((log, i) => (
            <div key={i} className={`log-entry log-${log.type}`}>
              <span style={{opacity: 0.6, marginRight: '8px'}}>[{log.time}]</span>
              {log.msg}
            </div>
          ))}
          {/* Invisible element to help auto-scroll if implemented */}
          <div style={{ float:"left", clear: "both" }} />
        </div>
      </div>

    </div>
  )
}

export default App
