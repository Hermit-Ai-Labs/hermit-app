import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { isApp } from './native'
import './fonts'
import './styles.css'

if (isApp) document.documentElement.classList.add('mac-app')

createRoot(document.getElementById('root')).render(<App />)
