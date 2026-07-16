# Dialogue Helper
Había una vez una pera que quería refactorizar el código de Claudio

## El camino del heroe

Para refactorizar, tuvo que analizar 2700 lineas de un solo script llamado "MainNode.gd"
Luego miro al abismo y el abismo le devolvió una lista de features que debía respetar

### Edición de texto:
1. Visualizar dialogos con las cajas de texto de Deltarune.
2. Ver una caja con el texto en inglés que no es editable.
3. Ver un TextEdit donde se pueda escribir la traducción.

### Importar y exportar archivos:
1. Cargar las líneas de diálogo de un txt con un formato específico.
2. Cargar de un txt recientemente abierto.
2. Exportar a json el contenido traducido con su correspondiente clave.
3. Guardar el progreso de la traducción en ese mismo txt.
4. Guardar el progreso de la traducción en un nuevo archivo txt.
5. Realizar periodicamente un guardado automático.
6. Cerrar archivo.
7. Cargar csv de referencias.

### Buscar líneas:
1. Encontrar una clave específica.
2. Agrupar claves similares por nombres parecidos.
3. Visualizar una lista de entries con las claves agrupadas.
4. Visualizar cada "ítem" al seleccionar cada entry.
5. Navegar por los items usando atajos de teclado.
6. Filtrar cada entry por su estado (traducido, sin traducir, revisión, etc.)
7. Buscar por el contenido o clave.

### Visualizar diálogos como si fuera in-game:
1. Detectar espaciado raro.
2. Usar retrato de personaje de ser necesario.
3. Ignorar etiquetas de tiempo, aplicar las demás.
4. Aplicar etiquetas de salto de linea.
5. Cambiar el tamaño de caja detectando ciertos patrones en la clave o en el contenido en inglés.

### Advertencias y mensajes:
1. Mostrar mensajes de etiquetas faltantes.
2. Mostrar advertencias de errores de signos sin cerrar.
3. Mostrar el progreso porcentual y absoluto de la traducción.
4. Mostrar el estado de cada entrada y cada ítem.
5. Mostrar advertencias de progreso sin guardar.
6. Mostrar mensaje de progreso autoguardado si no se cerro correctamente.

## Errores e inconsistencias en el código
- IClass -> Esto no es propio del estilo de gdscript. Ademas de que ni siquiera se respeta el uso correcto de interfaces.
- Las interfaces funcionan como instancias de clase o clases estáticas
- Algunas clases tienen el prefijo I y podrían reemplazarse como resources.
- La clase _Handle_ tiene demasiadas responsabilidades
- El _MainNode_ tiene demasiadas responsabilidades y mucho código perteneciente a otros nodos.
- Algunas funciones deberían ser marcadas como estáticas porque no acceden a ningún atributo interno de la clase.
- Se están ignorando advertencias de sobreescritura de variables heredadas como "char".
- Hay funciones que únicamente llaman a otras funciones XD
- La clase handle "Handle" conoce a "MainNode" y viceversa.
- Algunos principios solid se tomaron vacaciones.
- nombres de variables muy cortos y poco descriptívos.
- en algunos métodos los parámetros usan el prefijo "_" cuando es una nomenclatura para "heredado/no usado" dentro de la función.
- se accede a métodos marcados como privados desde otras clases XD
