# Uso de inteligencia artificial

Usamos Claude Code (modelo Claude Opus 5.5) como asistente durante el reto. Abajo está cada uso, qué produjo y qué decidimos o corregimos nosotros.

## Uso 1
- Herramienta: Claude Code (Claude Opus 5.5)
- Para qué se usó: entender el reto completo y diagnosticar los diez incidentes antes de tocar código
- Prompt principal (resumido): "Explícanos paso a paso el reto Terminal Rescue para poder resolverlo y entenderlo", con el ZIP del kit adjunto
- Qué produjo: el diagnóstico de cada incidente, las reglas del cierre comprobadas contra las huellas PBKDF2 del validador y una guía de trabajo para los dos integrantes
- Qué modificó o corrigió el equipo: la IA propuso crear un repositorio nuevo llamado fesc-terminal-rescue; nosotros ya habíamos creado HackatonJCyDD, así que usamos ese y decidimos reemplazar el README automático que GitHub le había puesto

## Uso 2
- Herramienta: Claude Code (Claude Opus 5.5)
- Para qué se usó: escribir los arreglos del worker, la API, el script de cierre, la configuración de Docker Compose y las correcciones SQL de la base
- Prompt principal (resumido): "Resuelve los diez incidentes respetando el contrato del reto y que ./run.sh dé siempre la misma salida"
- Qué produjo: worker.py, app.py, scripts/cierre.sh, scripts/cierre.py, db/init/03_correcciones.sql y los cambios de docker-compose.yml y .env.example
- Qué modificó o corrigió el equipo: la IA no pudo probar con Docker porque el PC de Daniel no lo tiene instalado; no dimos el entorno por bueno hasta que GitHub Actions lo levantó desde cero en Linux y el validador dio 10 de 10

## Uso 3
- Herramienta: Claude Code (Claude Opus 5.5)
- Para qué se usó: subir el proyecto a GitHub y repartir los commits entre los dos integrantes
- Prompt principal (resumido): "Hazme los commits de GitHub" y después "¿puedes hacer también los commits de Juan con su cuenta?"
- Qué produjo: los commits de Daniel con permiso de ejecución 100755 en los scripts y el push al repositorio; se negó a firmar commits a nombre de Juan
- Qué modificó o corrigió el equipo: aceptamos que cada uno firme solo su propio trabajo, así que Juan hizo sus commits él mismo desde un Codespace con su cuenta GGJUAN00, siguiendo los pasos de la guía

## Uso 4
- Herramienta: Claude Code (Claude Opus 5.5) con la extensión Claude in Chrome
- Para qué se usó: invitar a Juan como colaborador del repositorio
- Prompt principal (resumido): "Envíale la invitación a GGJUAN00"
- Qué produjo: abrió la configuración de acceso del repositorio en el Chrome de Daniel
- Qué modificó o corrigió el equipo: GitHub pidió confirmar el acceso con la cuenta de Daniel antes de cambiar colaboradores; Daniel confirmó su identidad él mismo y la invitación quedó enviada desde esa pantalla

## Uso 5
- Herramienta: Claude Code (Claude Opus 5.5)
- Para qué se usó: generar la evidencia de cada incidente y redactar incident-report.md
- Prompt principal (resumido): "Haz un script que guarde la salida real de la terminal antes y después de cada arreglo"
- Qué produjo: scripts/evidencias.sh, que levanta el kit original en una copia aparte y luego el repositorio corregido, y el borrador del informe de incidentes
- Qué modificó o corrigió el equipo: Juan corrió el script en su Codespace, comparó cada archivo de evidence/ con el informe, ajustó las frases que no coincidían con la salida real y revisó con grep que no apareciera la contraseña de .env.example
